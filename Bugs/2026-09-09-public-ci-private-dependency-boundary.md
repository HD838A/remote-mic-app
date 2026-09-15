# 公开 CI 被私有依赖权限阻断

## 状态与影响

- 状态：已修复，本地公开/私有双路径与 PR CI 验证通过。
- 影响范围：公开仓库贡献者、Fork PR、macOS Apple Silicon 与 Intel Ventura CI，以及受保护发布构建。
- 错误行为：公开 `Package.swift` 直接声明私有 `sayall-mac-remote` Git 依赖。没有该仓库权限的用户在 SwiftPM resolve 阶段失败，无法编译、测试或运行公开项目；若简单跳过 CI，则官方检查也会失去公开基线和私有集成覆盖。
- 正常行为：公开 checkout 不接触私有 Git URL并始终完成公开测试和构建；官方 CI 有权限时追加私有集成检查；受保护发布缺少私有组件时继续失败。

## 复现与证据

1. 在没有 `GetSayAll/sayall-mac-remote` 权限和本地 mirror 的环境执行 `swift package resolve --disable-keychain`。
2. 修复前 SwiftPM 会尝试解析私有 Git URL，并在认证阶段停止，后续 `swift test`、Release build 和 App 构建均无法开始。
3. CI 同样把私有 checkout 放在产品测试前，Fork 或 Secret 不可用场景无法证明公开源码自身是否健康。

这是构建控制面问题，没有 App 运行日志。可审计证据是 SwiftPM 依赖图、GitHub Actions 步骤状态和构建输出；CI 只输出私有访问可用/不可用的布尔结论，不输出 deploy key 或认证错误正文。

## 根因

公开 Package manifest 把发布时需要的私有实现误当成所有开发者都必须解析的基础依赖，混淆了三条不同边界：

- 公开源码的最低可编译、可测试、可运行契约；
- 官方 CI 有权限时执行的额外私有集成检查；
- 正式发布必须具备全部私有组件的 fail-closed 门禁。

## 修复

- `Package.swift` 改为通过 `SAYALL_MAC_REMOTE_PACKAGE_PATH` 显式加载私有 Package；默认使用公开兼容 target，不再解析私有 Git URL。
- 公开兼容 target 只实现宿主所需的公开接口，并把 Phone、Watch、Web 私有连接能力明确置为不可用，不复制私有仓库实现。
- macOS CI 始终在清空全部私有 Package 路径后运行完整 Swift tests、项目 self-test 和双架构 Release build。
- CI 仅在三项固定私有依赖的 deploy key 和实际 Git 访问都可用时，checkout 固定 Commit 并追加私有完整测试与双架构构建；否则只跳过这些额外步骤。
- 每个私有仓库探测使用独立 `ssh-agent`，其中只加载当前 deploy key。探测不设置缺少对应 `IdentityFile` 的 `IdentitiesOnly=yes`，避免错误忽略已加载的 agent key并把官方 CI 误判为无权限。
- 受保护发布 Workflow 显式设置三个私有 Package 路径和 `REQUIRE_*` 门禁，缺少 Mac Remote 私有 Package 时在构建前失败。

## 验证

- 公开 `swift package resolve --disable-keychain`：通过，依赖图只有公开 Sparkle。
- 公开 `swift test --disable-keychain`：458 项通过。
- 公开 Apple Silicon Release build：通过。
- 公开 Intel Ventura Release build：通过。
- 零私有路径 `scripts/build-app.sh`：成功生成并校验 `dist/SayAll.app`。
- 固定三项私有 Package 路径 `swift test --disable-keychain --scratch-path .build-private/local-merged`：462 项通过，包含私有 Watch BLE 旅程测试。
- `scripts/test-macos-release-flow.sh`、`scripts/verify-release-dependency-pins.sh`、`SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh`：通过。
- PR #392 的 [macOS CI Run 34294743333](https://github.com/HD838A/remote-mic-app/actions/runs/34294743333)：Apple Silicon 与 Intel Ventura 均先完成公开完整测试、self-test 和 Release build；随后实际 checkout 三项固定私有依赖，并完成私有完整测试与对应架构 Release build。所有步骤通过，私有步骤不是 skipped。

## 验证边界

本地验证证明公开与私有 Package 组合均可编译、测试，公开 App bundle 可生成并通过签名结构校验；官方 PR CI 已证明仓库 Secret 可用时私有步骤实际执行。Fork 无 Secret 时的跳过状态仍由条件逻辑和公开路径强制环境验证覆盖，没有另建外部 Fork fixture；真实用户图形界面启动仍属于后续人工环境验收。本次不改变运行时协议、音频、HID 或用户数据。
