# macOS 签名发布并发缓存冲突与无限等待

- 时间：2026-08-16
- 状态：已修复，等待下一次真实受保护工作流验证
- 影响范围：`macOS Signed Release Packages`，Apple Silicon 与 Intel 并行签名打包
- 功能点：SwiftPM 依赖下载、Developer ID 签名、公证、PKG/DMG 打包
- 简单描述：双架构并行时共享 SwiftPM 全局 artifact cache，且签名打包命令没有子超时或总步骤硬上限，导致一次发布先出现 Sparkle 下载冲突，随后 Intel `pkgbuild` 无输出等待约 157 分钟。

## 复现证据

现场为 GitHub Actions Run `31927320998`、Job `95116824099`。完整取消日志保存在本机：

```text
/private/tmp/open-voice-bridge-v1.8.24-cancelled-run.zP4BuZ
```

可重复的触发条件：

1. 工作流同时设置 `PARALLEL_RELEASE_VARIANTS=1`，并行启动 Apple Silicon 与 Intel lane。
2. 两个 lane 使用不同 `--scratch-path`，但没有传 SwiftPM `--cache-path`。
3. 两个 lane 在首次下载 Sparkle 2.9.4 binary artifact 时仍共享 `~/Library/Caches/org.swift.swiftpm/artifacts`。
4. 发布命令直接调用 `pkgbuild`、`productbuild`、`notarytool --wait` 等潜在长操作，没有单项 timeout、周期 heartbeat 或 10 分钟总步骤上限。

错误结果：

- 两个 lane 在 `04:46:58Z` 同时下载 Sparkle binary artifact；Apple Silicon lane 报 `already exists in file system`。
- Intel lane 的 App 公证在约 17 秒内 Accepted，Driver 在 `04:48:48Z` 完成并通过验证。
- 日志随后停在 `build-doubao-driver-pkg.sh` 调用区间，直到 `07:25:38Z` 人工取消。
- Runner 清理阶段明确报告回收 orphan `pkgbuild` PID `20538` 及其 zsh 父进程。

正常边界：

- Intel App 的签名、公证、staple 和验证均已完成，不能把本次长等待归因于 App 公证。
- Driver 的 Xcode build、签名和验证均已完成，不能把静默区间归因于 Driver 编译。
- 日志没有进入 PKG 公证，因此不能把静默区间归因于安装包 `notarytool`。

## 日志结论

1. SwiftPM 冲突根因已确认：`--scratch-path` 只隔离构建目录，没有隔离 SwiftPM 共享下载/binary artifact cache。
2. 无限等待位置已缩小到 Intel 安装组件的第一个带签名 `pkgbuild`；Runner 取消时仍存在该进程。
3. `pkgbuild` 为什么没有返回，现有日志不能进一步区分 Apple timestamp、Keychain/签名服务或工具自身等待。不能把其中任何一种推测写成已确认根因。
4. 流水线结构性根因已确认：潜在长操作均无子超时，签名 composite step 也只有 180 分钟 job timeout；一个子命令不返回就会无限占用到 job 上限。

## 精确修改范围

- `.github/workflows/mac-release-package.yml`：签名 composite step 增加 10 分钟硬 timeout，并从步骤入口启动受控 supervisor。
- `scripts/run-release-stage.sh`：新增无凭据阶段 supervisor，输出 lane/stage/elapsed heartbeat，超时终止完整子进程树并返回 `124`。
- `scripts/package-macos-release-variants.sh`：并行 lane 改为 fail-fast；任一 lane 失败立即终止另一 lane，并等待清理完成。
- `scripts/build-app.sh`：为每个 lane 同时隔离 SwiftPM scratch 与 cache；Release 模式下给 Swift build 和 timestamp codesign 增加子超时。
- `scripts/build-doubao-driver.sh`、`scripts/build-doubao-driver-pkg.sh`、`scripts/build-dmg.sh`、`scripts/notarize-release.sh`：只在签名发布模式启用阶段日志和对应长命令子超时。
- `scripts/test-release-pipeline-optimization.sh`、`Tests/RemoteMicTests/BuildSigningTests.swift`：覆盖 10 分钟阈值、cache 隔离、超时进程树清理、并发失败传播和阶段日志。
- `Testing/MacSignedReleaseTimeout.md`：记录无 Apple 凭据验证和下一次真实签名发布的验收边界。

不修改产品功能、签名身份、证书、Notary 凭据、候选分支、Tag 或 Release。

## 修复与验证

已完成以下无凭据验证：

- 使用两个全新的独立 SwiftPM cache/scratch 目录，并行解析 Apple Silicon 与 Intel 依赖；两个 lane 均成功并各自下载 Sparkle binary artifact，没有再出现 `already exists in file system` 或 `failed downloading`。证据目录：`/private/tmp/remotemic-swiftpm-cold2.ZL5asT`。
- `scripts/test-release-pipeline-optimization.sh` 通过：覆盖 2 秒确定性 timeout、heartbeat、父/孙进程树清理和双 lane fail-fast。
- `BuildSigningTests` 14 项通过。
- 项目自检 42/42 通过，Debug build 成功。
- 修改涉及的 shell 均通过 `zsh -n`；GitHub Actions YAML 可解析；`actionlint -ignore SC2129` 通过。未忽略时仅报告工作流原有的多次 `$GITHUB_ENV` redirect，位置不在本次修改范围。

第一次本机冷缓存验证因图形会话锁屏导致登录 Keychain 返回 `status -128`。这不是 SwiftPM cache 隔离失败；后续验证禁用本机 Keychain/netrc，并将私有依赖镜像到本地，只验证无凭据的真实并发冷缓存下载路径，结果通过。正式发布工作流仍必须使用其隔离发布 Keychain，不能照搬本机验证参数禁用发布 Keychain。

真实验证边界：本次没有访问 Apple 凭据，没有运行 Developer ID 签名、公证、staple、Environment 审批或发布。下一次受保护工作流必须确认签名 composite step 在 590 秒由内部 supervisor 开始清理，并在 GitHub 10 分钟硬上限内结束；同时确认超时后没有遗留 `codesign`、`pkgbuild`、`productbuild`、`notarytool`、`hdiutil` 或其子进程。

`TODO.md` 没有对应的独立流水线超时条目，因此本次不修改 TODO 状态。
