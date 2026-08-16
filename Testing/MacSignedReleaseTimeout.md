# macOS 签名发布超时与并发隔离测试手册

## 适用范围

- 适用分支：包含 2026-08-16 签名发布超时修复的 `main` 或开发分支。
- 适用工作流：`macOS Signed Release Packages`。
- 本手册只验证发布流水线的进程、缓存和日志边界，不代替真实 Developer ID 签名、公证、安装或 App 功能验收。

## 测试前准备

1. 使用干净的隔离 worktree，不使用任何候选发布分支。
2. 不提供 Apple 证书、Notary API Key、Match 密码或 Sparkle 私钥。
3. 确认 `zsh`、Swift 6.2、`rg` 和 YAML 解析工具可用。

## 用例 1：签名步骤 10 分钟硬上限

1. 检查 `.github/workflows/mac-release-package.yml` 的签名步骤。
2. 确认该 step 的 `timeout-minutes` 为 `10`。
3. 确认步骤从入口经过 `run-release-stage.sh`，并配置小于 GitHub 硬上限的内部清理预算。

预期结果：签名步骤运行满 10 分钟即停止等待并失败；内部 supervisor 在 590 秒开始终止完整子进程树并返回 `124`，为 GitHub 的 600 秒硬停止和 Keychain、临时文件清理保留少量时间。

失败判定：只保留 180 分钟 job timeout、仅依赖人工取消，或 timeout 后仍留下 `notarytool`、`pkgbuild`、`productbuild`、`hdiutil` 子进程。

## 用例 2：双 lane SwiftPM 冷缓存隔离

1. 为 Apple Silicon 和 Intel 使用两个全新 cache/scratch 目录。
2. 同时执行依赖解析或 Release build。
3. 检查命令行和最终目录。

预期结果：两个 lane 的 `--scratch-path` 与 `--cache-path` 均不同；首次并发下载 Sparkle binary artifact 不再访问同一个 `org.swift.swiftpm/artifacts` 路径，也不出现 `already exists in file system`。

失败判定：只隔离 `.build`/scratch，下载或 binary artifact cache 仍指向用户全局目录或同一 lane 目录。

## 用例 3：单阶段 timeout 清理完整进程树

1. 使用假命令启动父进程和长时间运行的孙进程。
2. 将阶段 timeout 缩短为 2 秒，heartbeat 缩短为 1 秒。
3. 等待 supervisor 返回。

预期结果：日志包含 lane、stage、elapsed、heartbeat 和 timeout；退出码为 `124`；父进程与孙进程均不存在。

失败判定：只终止父 shell，后台子进程继续运行，或日志无法指出超时 lane 和 stage。

## 用例 4：并行 lane 失败传播

1. 使用假 lane runner，让 Intel 快速返回非零，让 Apple Silicon 保持长时间运行并产生子进程。
2. 运行 `PARALLEL_RELEASE_VARIANTS=1 ./scripts/package-macos-release-variants.sh`。

预期结果：父脚本立即返回失败，终止 Apple Silicon 的完整进程树并等待清理，不等待其自然结束。

失败判定：父脚本报告成功、等待失败 lane 之外的任务直到超时，或留下孤儿进程。

## 用例 5：阶段日志与敏感信息边界

1. 静态检查 App build/sign/notary、Driver build、installer/uninstaller PKG、DMG、staple/verify 的阶段调用。
2. 执行假命令回归脚本。

预期结果：每个阶段输出开始、周期 heartbeat、完成/失败和耗时；日志只含稳定的 lane/stage 标签，不开启 xtrace，不打印凭据、邀请码、设备标识、Token 或私钥路径内容。

失败判定：长操作完全无输出，或日志包含 secret 值、命令环境 dump、`set -x`/`xtrace`。

## 用例 6：Installer 最终产品签名与跨 lane 串行

1. 静态检查 `build-doubao-driver-pkg.sh`：component `pkgbuild` 不带 `--sign`，Distribution `productbuild` 先输出 unsigned product archive。
2. 确认正式签名前先创建最小 nopayload probe PKG，并通过有界 `productsign` 验证 Developer ID Installer 私钥可用性。
3. 使用两个无凭据 fake signer 同时请求同一个 `lockf -k -t` lock file。
4. 检查最终验证器对展开后的 `RemoteMicComponent.pkg` 要求 `Status: no signature`，同时仍对外层可分发 PKG 执行 Developer ID Installer、staple 和 `spctl -t install` 检查。

预期结果：两个 fake signer 的 `start/end` 成对出现，不发生重叠；只有最终安装和卸载产品执行真实 `productsign`；架构提示 Distribution 不变；锁等待和单项签名仍受 timeout 限制。

失败判定：component 恢复 `pkgbuild --sign`、外层产品没有最终 Installer 签名、两个 lane 可同时进入 Installer 私钥操作、锁无限等待、探针被省略，或验证器只检查内层 component 而没有检查外层签名与 Gatekeeper。

## 稳定功能回归

- 普通 ad-hoc App/DMG 构建在未启用 release timeout 时仍按原路径执行。
- Apple Silicon 与 Intel 的输出名称、最低系统、架构、签名身份类型和 appcast 名称不变。
- 任一 lane 或并行 PKG 公证失败时，整个签名任务必须失败。
- 无 Apple 凭据测试不得触发真实签名、公证、Environment 审批或发布。

## 日志收集

- 保存 `scripts/test-release-pipeline-optimization.sh` 输出。
- 保存双 lane 冷缓存命令及 cache/scratch 目录清单。
- 下一次真实工作流保存每个阶段的开始、heartbeat、结束和 elapsed；失败时记录 lane/stage 与退出码。
- 不保存或粘贴 Apple 私钥、P8 内容、Match 密码、Keychain 密码或 Sparkle 私钥。

## 自动化、代理实测和真实发布边界

- 自动化可以证明参数隔离、确定性 timeout、进程树清理、并发失败传播和日志格式。
- 代理可在无凭据环境运行并发冷缓存解析/构建和 shell/YAML/Swift 测试。
- 只有下一次受保护工作流才能证明真实 timestamp、Developer ID、Apple Notary、staple 和 GitHub Runner 取消行为；本次修复不 dispatch、不审批、不签名、不公证、不发布。

## 2026-08-16 验证记录

- 双 lane 真实全新冷缓存并发解析通过：Apple Silicon 与 Intel 使用各自的 SwiftPM `--scratch-path` 和 `--cache-path`，均独立下载 Sparkle artifact，无共享 artifact 冲突。证据目录：`/private/tmp/remotemic-swiftpm-cold2.ZL5asT`。
- `scripts/test-release-pipeline-optimization.sh` 通过：2 秒 timeout 返回 `124`，可见 heartbeat，父进程和孙进程均被清理，任一 lane 失败会立即取消另一 lane。
- `BuildSigningTests` 14 项通过；项目自检 42/42 通过；Debug build 成功。
- 修改 shell 通过 `zsh -n`，工作流 YAML 解析通过，`actionlint -ignore SC2129` 通过。
- 本机第一次冷缓存测试遇到锁屏登录 Keychain `status -128`；该次结果不计入 cache 隔离验收。最终冷缓存验证禁用本机 Keychain/netrc 并使用本地私有依赖镜像，仅证明无凭据下载和 cache 隔离边界。
- 尚未执行真实 Developer ID timestamp、Installer 签名、Apple 公证、staple、GitHub 10 分钟取消和受保护 Runner 清理；这些项目必须由下一次真实候选工作流补验。

## 2026-08-16 第二次真实工作流与修复记录

- Run `31938200895` 证明 App 公证正常：Apple Silicon 与 Intel 均在约 25–26 秒返回 `Accepted`。
- 两个 lane 随后同时进入带 Developer ID Installer 的 `installer-component-pkgbuild`，均无工具输出并在 90 秒返回 `124`；fail-fast 正确取消另一 lane，完整步骤约 326 秒失败，没有上传资产。
- 对照 `v1.8.23` Run `31806292978`：unsigned `pkgbuild` 后对最终 PKG 执行 `productsign`，两架构均在约 1–2 秒内完成，最终公证和验证通过。
- 无凭据 product archive 结构实验确认 Distribution `productbuild` 会把 component 纳入外层 archive；component 可保持 unsigned，最终验证边界是外层 product archive。
- 自动化新增 component unsigned、外层最终 productsign、最小 nopayload 签名探针、`lockf` 跨 lane 串行、外层签名/公证/Gatekeeper 验证门禁。
- 本机双架构 ad-hoc 完整链通过：Apple Silicon component `pkgbuild` 约 2 秒、Distribution `productbuild` 约 1 秒；Intel component `pkgbuild` 约 1 秒、Distribution `productbuild` 约 2 秒。两套 PKG/DMG 验证均通过，架构提示 Distribution 保持不变。
- `BuildSigningTests` 14/14、installer architecture guard、release pipeline optimization regression 均通过。
- 本轮未访问 Apple 凭据；下一次必须使用更高版本/Build 的新候选，从包含本修复且双架构 CI 通过的最新 `origin/main` 创建。不得重跑旧 `1.8.25` 候选。
