# App 内安装 Siri Remote helper 后被判定为 installation_invalid

- 时间：2026-11-19
- 状态：候选修复，等待隔离系统状态下的真实 `SMJobBless` 安装和语音上屏验收
- 影响范围：未通过 PKG 安装 Siri Remote 组件、随后在 App 连接页点击“启用”并完成管理员授权的用户
- 用户现象：遥控器卡片持续显示“语音异常”；再次点击“启用”不再出现管理员密码窗口

## 错误证据

`2.0.9 (407)`、源码 `a70be3b` 的脱敏运行日志：

```text
15:31:59 SIRI REMOTE COMPONENT ... helper_present=false launch_daemon_present=false
15:32:15 REMOTE CARD_ACTION phase=requested action=enable source=user
15:32:19 APPLE REMOTE HCI upgrade phase=failed
         reason=authorization_helper_upgrade_installation_invalid
15:32:19 SIRI REMOTE COMPONENT ... helper_present=true launch_daemon_present=true
         component_installed=true
         audio_status=unavailable:authorization_helper_upgrade_installation_invalid
```

同一组日志中，15:20 已存在的旧 helper 通过 `installed_version_verified`；15:31 重装后 helper 缺失；15:32 由 App 内 `SMJobBless` 写入后立即校验失败。后续 15:33、15:34、15:36 的点击重复相同失败码，且不再弹出密码窗口。

安装系统文件和重新校验是两条路径：`SMJobBless` 写入 helper 和 LaunchDaemon 成功，`AppleRemoteHCIServiceUpdater.readInstalledVersion` 随后拒绝了该安装。问题不来自遥控器连接、蓝牙或音频设备。

## 根因

旧版 `readInstalledVersion` 只接受一种 LaunchDaemon 形态：

```text
ProgramArguments == [helper path]
Program == nil
```

App 内 `SMJobBless` 写入的 plist 可以包含 `Program`，而旧 PKG 安装的 plist 只包含 `ProgramArguments`。因此旧安装能通过，App 内新安装却被拒绝。校验失败在安装入口前抛出，后续点击不会覆盖已被判定为不可信的 helper，也不会再次请求管理员授权。

## 修复

私有平台 `2.12.5`（Tag Commit `2bb91509`）：

- `launchdProgramMatches` 同时接受 `Program` 和 `ProgramArguments`；两者都存在时，所有可观察到的可执行路径仍必须等于预期 helper 路径。
- 可执行路径不是预期 helper、出现额外参数、缺少 executable、owner/mode、签名或版本异常时继续拒绝。
- 把通用安装失败细分为 `..._system_path`、`..._launchd`、`..._signature` 和 `..._version`，后续日志能定位失败条件。
- 公开宿主把私有依赖 `2.12.4` 升级到 `2.12.5`。

## 验证

- 私有 `swift test --disable-keychain --package-path packages/audio-input-kit/siri-remote --filter AppleRemoteHCIServiceUpgradeTests`：13 项通过。
- 私有新增回归覆盖 `ProgramArguments`、`Program`、两者同时存在、额外参数、错误路径和缺失 executable。
- 私有 `2.12.5` 发布流程完成 release 构建、测试、归档、Tag 和资产发布。
- `scripts/verify-release-dependency-pins.sh`：`RELEASE DEPENDENCY PINS PASS`，私有包解析到 `2.12.5`。
- 公开 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build-public`：合并最新 `origin/main` 后 1517 项测试、112 个套件通过；`AppleRemoteComponentInstallationTests` 与 `SiriRemoteActivationTests` 定向 7 项通过。
- 公开 `scripts/verify-repository-governance.sh`：通过。
- 使用 `2.12.5` 预构件和独立 scratch path 执行 `swift build --disable-keychain`：通过，确认公开宿主能链接新私有模块。
- 本地集成测试 App：`2.0.8 (404)`，源码 `1ab3aec8`（其后只有本文档修订），`SayAllPrivatePlatformVersion=2.12.5`，Developer ID `L3QHLDRPAY`，安装到 `~/Applications/SayAll.app`。
- 启动后日志：`helper_present=true launch_daemon_present=true component_installed=true`，`SIRI REMOTE AUDIO phase=ready result=capture_available`；当前机器上的已安装 helper 不再被判为 `installation_invalid`。
- 未完成真实 `SMJobBless` 全新写入：需要先移除或替换已有特权组件，当前没有执行该破坏性系统改动；管理员授权和全新安装形态仍待隔离系统或用户现场验证。

## 验证边界

- 已有错误安装文件仍留在系统路径；更新到包含 `2.12.5` 的 App 后，下一次“启用”会重新校验，通过后恢复语音。若真实 helper 签名或版本确实不匹配，会显示新的细粒度失败码，仍需独立的修复入口。
- 私有测试使用受控 fixture 验证 plist 形态，不能替代真实 `SMJobBless` 写入、管理员授权、隔离系统状态和真实遥控器语音文字上屏。
- 本次未修改安装签名、LaunchDaemon 标签、helper 路径或语音音频链路。
