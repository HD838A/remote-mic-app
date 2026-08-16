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

预期结果：步骤超过 10 分钟时由 GitHub 强制失败；内部 supervisor 会提前终止完整子进程树并返回 `124`，为 Keychain 和临时文件清理保留少量时间。

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
