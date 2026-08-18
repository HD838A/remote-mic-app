# macOS 1.9.0 签名流程的 Swift Release 冷构建被 180 秒误杀

- 时间：2026-08-19
- 状态：代码修复完成，等待受保护 Developer ID canary
- 影响范围：macOS `1.9.0` 双架构签名候选；GitHub hosted macOS Runner 的首次干净 Release 构建
- 功能点：`macOS Signed Release Packages` 的阶段超时预算
- 简单描述：Apple Silicon 与 Intel 仍在正常并行编译时，两个 `app-swift-build` 都被固定 180 秒子阶段提前终止，导致签名、公证尚未开始就失败。

## 复现

GitHub Actions Run `32176710841`、Job `95840322389` 在候选提交 `58a37af409540f819aa363b0857a43a786e80876` 上执行双架构受保护打包。完整日志保存在：

```text
/private/tmp/v190-signed-run-32176710841.log
```

触发条件：首次干净 hosted Runner、同时构建 Apple Silicon 与 Intel、同时注入 SayAll AI 与组合动作私有组件、Swift Release 配置。

错误结果：Intel 在 180 秒、Apple Silicon 在 181 秒由 `app-swift-build` timeout 返回 `124`；父 `app-build` 和 `signed-variant` 正确传播失败，另一 lane 被 fail-fast 取消，`signed-release` 在 191 秒失败。

正常边界：日志中没有 `codesign`、`notarytool` 或 stapler 的失败；隔离 Keychain 探针和 Notary 凭据验证已通过。外层 590 秒 supervisor 没有超时，而是对真实子阶段失败快速返回。

## 日志结论

- `19:29:59Z` 两个 lane 同时进入 `app-swift-build timeout=180s`。
- SwiftPM 完成依赖解析和 Sparkle artifact 下载后持续编译主程序、SayAllAI、SayAllMacroRemoteMic 与 SayAllMCP。
- `19:32:59Z` Intel、`19:33:00Z` Apple Silicon 超时；超时前最后可见事件仍是正常编译和阶段 heartbeat，没有 hang、崩溃或网络错误。
- 两个 lane 在相同阈值附近同时失败，证明 180 秒是过紧的静态预算，不是单一架构或签名身份故障。

## 代码检查与根因

`scripts/build-app.sh` 将 `RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS` 固定默认为 180 秒；`scripts/notarize-release.sh` 又用 240 秒的 `app-build` 包住整个 App build。该预算来自较小的历史构建，未覆盖 1.9.0 新增目标和两个完整私有组件在干净 Runner 上并行竞争 CPU 的成本。

根因是子阶段预算失真。签名、Apple 公证、Sparkle、Keychain、双 lane scratch 隔离和 590/600 秒硬停止均不是本次根因。

## 最小修复

- `app-swift-build` 默认预算调整为 300 秒。
- 仅包住 `build-app.sh` 的 `app-build` 父阶段同步调整为 330 秒，保留 30 秒组装、strip、资源复制和签名余量。
- 保持 `signed-variant=560s`、`signed-release=590s`、GitHub 签名 step `600s` 不变；没有取消 timeout、没有自动重试，也没有提高完整签名流程硬上限。
- 新增 `verify-release-timeout-budgets.sh`，要求 `300 < 330 < 560 < 590 < 600` 的父子边界成立，并固定拒绝旧 180 秒预算和父子倒挂。
- 受保护 canary 必须使用专用 `release/pre-vX.Y.Z-canary-name` 分支并输入 exact commit 与 release pipeline 聚合 SHA-256；远端分支 head 必须等于该提交。Canary 使用 `mac-release` Environment 和真实 Developer ID/Notary 路径，但跳过普通候选分支、Tag 和 Draft PR 规则，不创建 Tag/Release，也不上传下载资产；普通候选 verifier 继续只接受不带后缀的 `release/pre-vX.Y.Z`。

## 验证

已完成：

- `scripts/verify-release-timeout-budgets.sh`：通过，输出 `300/330/560/590/600`。
- 反向 mutation：把 Swift build 恢复为 180 秒会被拒绝；把 `app-build` 改为 300 秒造成父子预算无余量也会被拒绝。
- `scripts/test-release-pipeline-optimization.sh`：通过，原有 timeout、完整进程树清理和并行 fail-fast 基线保持不变。

待完成：

- 在修复提交 Push 后运行受保护 Developer ID canary，必须验证 exact committed pipeline digest；canary 通过前不得合入 `main`。
- Canary 只证明修订后的真实签名、公证路径和时间预算可完成，不创建候选发布，也不代替 1.9.0 最终 exact-SHA 产品门禁。

`TODO.md` 没有对应的独立发布超时条目，因此本次不修改 TODO 状态。
