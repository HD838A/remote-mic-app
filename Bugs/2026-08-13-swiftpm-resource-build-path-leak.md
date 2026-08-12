# SwiftPM 资源构建路径进入发布 App

## 复现

1. 在位于 `/Users/...` 的仓库 worktree 中配置 SayAllAI 私有 Swift Package。
2. 执行 `scripts/build-app.sh` 生成 Release App。
3. 对最终 `RemoteMic` 可执行文件执行本地路径扫描。

错误行为：SwiftPM 自动生成的 `resource_bundle_accessor.swift` 将当前 scratch 目录写为字符串常量，最终可执行文件包含构建机器的绝对用户目录。

正常行为：发布 App 不包含构建机器的用户目录，同时仍能从 App Resources 加载 SayAllAI 资源 bundle。

## 日志结论

`macOS Preview Candidate` run `31619676326` 的 Apple Silicon 与 Intel 任务均完成测试、首次语音门禁和 Self Test，随后在 `verify-app.sh` 的本地路径扫描中失败：

```text
bundle contains a forbidden local path or example device address
```

本地使用 `/Users/...` worktree 重建后，`strings` 确认命中内容来自 SwiftPM 生成的 `SayAllAI/resource_bundle_accessor.swift`，不是 Homebrew tap trust 警告、产品日志或文档资源。

## 根因

`scripts/build-app.sh` 默认把 SwiftPM scratch 放在仓库内。SwiftPM 资源 target 会把资源 bundle 的绝对构建路径编译进 fallback accessor，因此仓库位于 `/Users/...` 时会泄露本机构建目录。

## 修复

将默认 SwiftPM scratch 固定到不含用户名、按版本、Build、架构和资源配置隔离的 `/private/tmp/remote-mic-swiftpm/...`。保留 `REMOTE_MIC_BUILD_SCRATCH_PATH` 显式覆盖能力，不降低最终 App 的敏感路径扫描。

## 验证

- `BuildSigningTests` 校验默认 scratch 不再位于 `$ROOT`。
- 使用 SayAllAI 私有 Package 重新构建最终 App，并再次运行 `verify-app.sh`。
- 预览候选必须重新通过 Apple Silicon 与 Intel 的完整 Actions 门禁。

## 验证边界

该修复只改变构建输出目录，不改变运行时功能、资源内容、签名身份或更新行为。签名、公证和公开资产仍由后续候选流水线验证。
