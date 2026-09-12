# 安装/卸载脚本在音频服务缺失时于成功之后报错中止

- 时间：2026-09-05
- 状态：已修复，自动化通过；真实安装器验收未完成
- 影响范围：`packaging/doubao-driver/install/postinstall`、`packaging/doubao-driver/uninstall/postinstall`、`scripts/install-doubao-driver.sh`、`scripts/uninstall-doubao-driver.sh`
- 功能点：驱动安装/卸载后的 coreaudiod 重启
- 简单描述：驱动文件已经就位（或已移入废纸篓）之后，脚本才调用 `killall coreaudiod` 重启系统音频服务。coreaudiod 不在运行时 killall 返回非零，`set -euo pipefail` 随即中止脚本——Apple 安装器只显示笼统的「安装失败」，用户会以为操作没成功并可能重复执行。与已记录的 bundle relocation 事故属同一形态：活干完了、随后报失败。

## 复现

1. 让 coreaudiod 不在运行（例如以 PATH 注入一个必然失败的 killall/pgrep 模拟）。
2. 执行驱动安装或卸载。

错误行为：脚本退出码非零，安装器报告失败；但驱动已经写入/移除完成。
正常行为边界：音频服务重启只影响系统何时加载新驱动，不影响安装结果本身。

## 根因

四个脚本把 `killall coreaudiod` 当作无条件必成功的收尾步骤：

- `packaging/doubao-driver/install/postinstall` 在 `DRIVER_CHANGED` 后裸调用，进程不存在即中止；
- `scripts/install-doubao-driver.sh`、`scripts/uninstall-doubao-driver.sh` 同样裸调用；
- `packaging/doubao-driver/uninstall/postinstall` 用 `2>/dev/null || true` 兜底——不会中止，但把权限不足等真实失败一并吞掉，且无任何提示。

另外 `scripts/verify-doubao-driver-pkg.sh` 曾逐字断言那行裸调用必须存在，任何防护性修改都会先被自己的验证脚本拦下——同一类「断言缺陷」。

## 修复

四个脚本统一改为 `restart_audio_service()` 三分支：

1. `pgrep -qx coreaudiod` 判定服务是否在运行，不在则如实提示「无需重启」；
2. `killall` 成功则提示已重启；
3. `killall` 真实失败单独成支，如实告知「驱动已就绪，请重启 Mac」，且不抑制 stderr，失败原因进入安装器日志。

三个分支都不中止脚本——驱动已就位，最坏只是系统稍后才加载。不使用 `|| true`，那会连权限失败一起吞掉。

验证脚本同步改为断言 `pgrep` 判定与 `elif killall` 条件形式存在，并增加反向门禁：裸 `killall coreaudiod` 行出现即构建失败。

## 验证

自动化：

- `BuildSigningTests.audioServiceRestartNeverAbortsInstallerScripts`：静态门禁（四个脚本禁止裸 killall/pkill 语句）+ 真实行为测试——从每个脚本中抽取**发布版原样的** `restart_audio_service` 函数，在 `set -euo pipefail` 下以 PATH 注入必然失败的 pgrep/killall 运行全部三种分支，断言退出码为 0 且提示文案与场景一致；
- `swift test` 全量通过；
- `zsh -n` 四个脚本语法检查通过；
- `scripts/verify-doubao-driver-pkg.sh` 的断言与新脚本结构一致。

未覆盖：

- 真实 Installer.app 安装/卸载界面验收（需候选包按 `Testing/MacInstallerUninstaller.md` 用例 5 实测）；
- coreaudiod 真实不存在的机器环境（自动化以 PATH 注入模拟）。
