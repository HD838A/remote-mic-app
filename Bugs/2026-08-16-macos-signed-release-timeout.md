# macOS 签名发布并发缓存冲突与无限等待

- 时间：2026-08-16
- 状态：已修复；`1.8.25 (119)` 已完成真实受保护 Developer ID 双架构验证
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
- `Testing/MacSignedReleaseTimeout.md`：记录无 Apple 凭据验证、后续真实签名结果和验收边界。

不修改产品功能、签名身份、证书、Notary 凭据、候选分支、Tag 或 Release。

## 修复与验证

已完成以下无凭据验证：

- 使用两个全新的独立 SwiftPM cache/scratch 目录，并行解析 Apple Silicon 与 Intel 依赖；两个 lane 均成功并各自下载 Sparkle binary artifact，没有再出现 `already exists in file system` 或 `failed downloading`。证据目录：`/private/tmp/remotemic-swiftpm-cold2.ZL5asT`。
- `scripts/test-release-pipeline-optimization.sh` 通过：覆盖 2 秒确定性 timeout、heartbeat、父/孙进程树清理和双 lane fail-fast。
- `BuildSigningTests` 14 项通过。
- 项目自检 42/42 通过，Debug build 成功。
- 修改涉及的 shell 均通过 `zsh -n`；GitHub Actions YAML 可解析；`actionlint -ignore SC2129` 通过。未忽略时仅报告工作流原有的多次 `$GITHUB_ENV` redirect，位置不在本次修改范围。

第一次本机冷缓存验证因图形会话锁屏导致登录 Keychain 返回 `status -128`。这不是 SwiftPM cache 隔离失败；后续验证禁用本机 Keychain/netrc，并将私有依赖镜像到本地，只验证无凭据的真实并发冷缓存下载路径，结果通过。正式发布工作流仍必须使用其隔离发布 Keychain，不能照搬本机验证参数禁用发布 Keychain。

第一轮修复当时的真实验证边界：该轮没有访问 Apple 凭据，没有运行 Developer ID 签名、公证、staple、Environment 审批或发布。后续 Run `31938200895` 已证明单阶段 timeout、完整进程树清理和双 lane fail-fast 会在真实受保护 Runner 生效；Run `31944719103` 已补齐正常成功路径的 Developer ID、timestamp、公证和 staple 验收。590 秒总 supervisor 的实际超时分支没有通过故意挂起真实签名来触发，继续由无凭据进程树测试和 GitHub 10 分钟 step 配置覆盖。

`TODO.md` 没有对应的独立流水线超时条目，因此本次不修改 TODO 状态。

## 第二次真实验收：有界门禁暴露 component 签名阻塞

GitHub Actions Run `31938200895` 在 2026-08-16 对 `1.8.25` 执行了修复后的受保护签名流程。完整失败日志保存在：

```text
/private/tmp/open-voice-bridge-v1.8.25-failed-run.WNEUIN
```

已确认的事件顺序：

1. Apple Silicon 与 Intel App 均完成 Developer ID 签名、验证和公证；两次 App 公证分别约 25–26 秒即返回 `Accepted`。
2. 两个 lane 随后并发进入 `installer-component-pkgbuild`，命令均为带 `--sign 'Developer ID Installer: … (L3QHLDRPAY)'` 的 component `pkgbuild`。
3. Apple Silicon 从 `09:12:59Z`、Intel 从 `09:13:00Z` 开始后均没有任何 `pkgbuild` 输出。
4. 两个阶段均在 90 秒达到 timeout 并返回 `124`；Apple Silicon 先失败后，双 lane fail-fast 正确取消 Intel，整个签名步骤在约 326 秒结束。
5. Upload 被跳过，没有创建或修改 Tag、Release 或公开资产。

因此，第一轮修复的 10 分钟硬上限、阶段 heartbeat、子超时、完整进程树清理和双 lane fail-fast 已在真实 Runner 生效。此次失败不能归因于 Apple Notary；阻塞点已精确定位为两个 lane 首次同时执行的 component `pkgbuild --sign`。

## 历史与工具证据

- `v1.8.23` 成功 Run `31806292978` 使用 unsigned `pkgbuild` 生成安装/卸载包，再由 `productsign` 对最终可分发 PKG 签名。Apple Silicon 与 Intel 的 `pkgbuild`、`productsign` 均在约 1–2 秒内完成，最终 PKG 后续公证、staple 和验证通过。
- Commit `d9ba8dfb` 为架构错误提示引入 Distribution 产品归档，同时将 component 改为 `pkgbuild --sign`、外层改为 `productbuild --sign`。`1.8.25` 是该双重签名方式首次真实 Developer ID 双 lane 并发验收。
- 本机 `pkgbuild(1)` 明确说明 component package 通常会由 `productbuild` 纳入 product archive；`productbuild(1)` 明确说明 Distribution 引用的 component 会被 incorporated into the resulting product archive；`productsign(1)` 用于给已经由 `productbuild` 创建的最终 product archive 添加或替换签名。
- 无凭据结构实验验证：unsigned component 经 Distribution `productbuild` 后被纳入外层 product archive；component 保持 `Status: no signature`，外层在签名前也是 `Status: no signature`。现有最终验证器针对外层 PKG 执行 Developer ID Installer 链检查，公证后再执行 `stapler validate` 和 `spctl -t install`。

## 第二次最小修复

- component `pkgbuild` 固定保持 unsigned，不再让两个 lane 对将被外层产品归档纳入的中间包执行无价值的 Developer ID Installer 签名。
- Distribution `productbuild` 先生成 unsigned 外层安装产品，继续保留中英文错误架构和最低系统提示。
- 签名前使用最小 nopayload PKG 执行一次有界 `productsign` 私钥可用性探针；探针通过后，再用 `productsign` 分别签最终安装与卸载 PKG。
- 所有必要的 Installer 私钥操作使用 macOS `lockf -k -t` 和同一个显式 `/private/tmp` lock file 跨 lane 串行；锁等待时间短于单项 productsign timeout，且不放宽 10 分钟总门禁。
- 最终验证器明确要求内层 component 无签名，并继续只把可分发外层 PKG 的 Developer ID Installer 签名、公证、staple 和 Gatekeeper 结果作为信任边界。

本机无凭据回归已经覆盖两套完整 ad-hoc 链：Apple Silicon component `pkgbuild` 约 2 秒、Distribution `productbuild` 约 1 秒；Intel component `pkgbuild` 约 1 秒、Distribution `productbuild` 约 2 秒。两套 PKG/DMG 验证通过，`BuildSigningTests` 14/14、installer architecture guard 和 release pipeline optimization regression 均通过。

本轮没有修改、创建或轮换证书，没有请求或输出 secret，没有重试挂起命令，也没有增加任何 timeout。当时尚待验收的 Developer ID 探针、跨 lane 串行 `productsign` 和最终外层 PKG 公证，已经由下述 Build 119 新候选完成，不是通过重跑失败候选获得。

## Build 119 真实 Developer ID 验收

GitHub Actions Run [`31944719103`](https://github.com/HD838A/remote-mic-app/actions/runs/31944719103) 使用候选提交 `1659b6c094b47e89016a3d6f8a6f81e972ad15f3` 构建 `1.8.25 (119)`，该提交的直接父提交为包含第二次修复的 `bba72af82084655ff688d38774376f4f6aaae5ff`。

- Apple Silicon 与 Intel 的 unsigned component `pkgbuild` 均约 1 秒完成；unsigned Distribution `productbuild` 均约 1 秒完成。
- 两个 lane 的 nopayload Developer ID Installer `productsign` 探针均约 2 秒完成，最终安装和卸载产品的 `productsign` 均约 1 秒完成。
- 两套 App、四个最终外层 PKG 和两套 DMG 均完成 Developer ID 签名、可信 timestamp、公证、staple 与对应 Gatekeeper 验证；内层 `RemoteMicComponent.pkg` 继续保持 unsigned。
- 完整 `signed-release` 阶段约 266 秒结束，GitHub step 约 4 分 26 秒完成，没有触发 590/600 秒门禁。
- 当前防回归测试直接提取 `installer-component-pkgbuild` 与 `installer-productbuild` 命令块，要求两者不含 `--sign`；测试会分别注入 `--sign` mutation，并要求两个变体都被拒绝，避免以后换一种变量名重新引入 Build 118 的触发路径。

仍然成立的边界：成功的 Build 119 证明正常真实签名链可用，但不会证明 Apple、Keychain 或网络服务永不出现新的瞬时失败；这些相邻故障必须继续由 45–120 秒单阶段 timeout、590 秒总 supervisor、GitHub 10 分钟硬上限和 fail-fast 约束为有界失败。
