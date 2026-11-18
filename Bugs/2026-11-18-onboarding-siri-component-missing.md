# Onboarding 苹果遥控器组件缺失时误显示重新授权

## 现象

用户在苹果遥控器语音测试页看到“苹果遥控器语音需要授权”和“重新授权”。点击“重新授权”没有可见反应。用户确认安装 PKG 时没有安装 Siri Remote 组件。

## 证据

- 用户截图：语音测试页显示语音键、语音声音和音频连接已收到，但文字未出现，同时显示授权待处理。
- 用户确认：系统组件未安装。
- 现有日志为 `RMLG2` 加密格式；本轮环境没有诊断私钥，未读取日志正文。结论以用户确认、代码路径和可重复自动化用例为依据。

## 根因

1. `FirstUseDiagnosticContext` 只根据持久化的 `siriRemoteNeedsUserAction` 判断 `voiceAuthorizationRequired`，没有检查 `isSiriRemoteHelperInstalled`。
2. 组件缺失时，私有组件状态可能包含 `authorization_`，于是 `BridgeAppModel` 把 `siriRemoteNeedsUserAction` 置为 true。Onboarding 因此把“组件未安装”误判为“授权待处理”。
3. 语音测试页的恢复操作只有“重新授权”，调用 `enableSiriRemoteForOnboarding()`。该路径不是明确的组件安装入口；语音会话收尾时还可能被 `activePhysicalVoiceControlSource` 保护提前返回，表现为点击无反应。
4. 设置页已经有组件安装模块，但 Onboarding 没有复用该状态和操作。

## 修复

- 新增 `voice.component_missing` 失败原因，并让它优先于 `voice.authorization_required`。
- Onboarding 读取 `model.isSiriRemoteHelperInstalled`；组件缺失时显示“Siri Remote 组件未安装”和“安装组件”。
- 点击“安装组件”调用 `installSiriRemoteComponentForOnboarding()`：先保存 Onboarding 进入时的 Siri Remote 启用状态，再调用现有组件安装路径请求管理员授权。
- 组件缺失时，安装路径不再被残留的 `activePhysicalVoiceControlSource` 挡住；已安装组件时仍保留语音会话保护，并记录明确的跳过原因。
- 组件安装请求日志增加 `source=onboarding`；语音会话活动时被跳过的安装也记录明确原因，避免再次出现无痕点击。
- 运行时日志和用户复制的诊断摘要新增脱敏组件状态：`build_supported`、`installer_receipt_present`、`helper_present`、`launch_daemon_present`、`component_installed`、`enabled`、`needs_user_action` 和当前 `audio_status`。用户不需要再手工执行 `test -x` 或查看系统路径。
- 中英文文案、产品规范、Onboarding 测试手册和组件安装测试手册同步更新。

## 验证

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter OnboardingFlowTests`：114 项通过。
- 增加 `SAYALL_SIRI_REMOTE_ENABLED` 编译开关后，`OnboardingFlowTests`、`SiriRemoteActivationTests`、`LocalizationTests` 与 `AppleRemoteComponentInstallationTests` 共 133 项通过，包含组件缺失优先于授权待处理、点击安装恢复动作和脱敏组件诊断字段的用例。
- 中英文浅色、深色生产离屏截图各生成一组；`07-voice-test.png` 均为 2040 × 1600，逐张确认显示“安装组件”而非“重新授权”。截图文件保存在仓库外 `/Users/andy/Develop/Src/AISrc/.screenshot-workdir/onboarding-siri-component-missing-20261118/`。
- 真实 helper / LaunchDaemon 安装、SMJobBless 取消与允许、两代苹果遥控器和第三方文字上屏必须由签名候选包现场验收；单元测试和截图不能替代。

## 边界

本次只修复 Onboarding 的状态识别和安装入口，不改变组件安装实现、PKG 组件选择、会员门禁、音频链路或语音键按下/释放语义。已安装组件但授权仍失败时仍走“重新授权”。
