# 控制来源未连接时 Onboarding 卡在音频页

- 时间：2026-11-20
- 状态：代码修复与自动化完成；真机待验证
- 影响范围：macOS Onboarding；选择小米遥控器或 Chromecast 遥控器，普通按键 HID 可用，但语音 BLE 链路未连接
- 功能点：Onboarding 音频页自动准备虚拟音频输出、音频页重试路径
- 简单描述：用户选中受支持的 `MiRemoteV 2ch` 后，音频页显示「语音输出还没有准备好」；点击「重试音频设置」没有任何变化，无法继续。
- 现场材料：用户提供的 `SayAll first-use diagnostics` 和本机 `runtime.log`；`app_version=2.0.8`、`app_build=410`、`macos_version=27.0.1`、`source_revision=b82e76916385c394899f42dc06de93e7aeef12fc`。

## 现场证据

关键诊断字段：

```text
step=audio
control_source=xiaomi_remote
control_method=physical_remote
failure=audio.output_not_ready
audio_device_selected=true
audio_device_available=true
audio_output_ready=false
audio_gate=ready_required
control_connected=false
control_button_observed=true
audio_status=audio.output.current_format
```

- `audio_device_selected=true`、`audio_device_available=true`：虚拟音频设备存在且已被选中，不是驱动缺失或名称不匹配。
- `control_connected=false`、`control_button_observed=true`：普通按键 HID 链路可用，但所选遥控器的语音链路没有连接。
- `audio_output_ready=false`：虚拟音频输出没有保持运行。
- `audio_gate=ready_required`：音频页要求持续 Ready，这是该页面原本的产品行为。
- `audio_status=audio.output.current_format`：这是启动时配置成功留下的旧状态，不代表当前仍 Ready。

对应运行日志：

```text
15:15:54.258 AUDIO READY target={name=MiRemoteV 2ch ...}
15:15:54.908 AUDIO RELEASE requested reason=bluetooth_not_ready ... ready_bridges=0
15:16:15.308 PUBLIC_EVENT ... component=remote action=connection phase=failed
             result=failed reason=bridge_failed ... remote_model_family=xiaomi
15:41:27.840 BLE CONNECTING ... source=target_identifier
15:41:35.836 BLE CONNECT TIMEOUT
...
15:44:21.662 ONBOARDING EVENT kind=blocked step=audio failure=audio.output_not_ready
15:44:27.578 ONBOARDING EVENT kind=retry step=audio failure=audio.output_not_ready
15:45:21.278 ONBOARDING EVENT kind=retry step=audio failure=audio.output_not_ready
```

- 启动时虚拟音频输出配置成功，随后因为没有 Ready 的蓝牙桥被释放。
- 小米遥控器语音链路此后反复连接超时，桥从未 Ready。
- 用户多次点击重试，但日志中没有新的 `AUDIO CONFIGURE`。

## 根因

1. 音频页要求所选虚拟音频输出持续 Ready。该要求本身正确，但页面进入时没有主动配置输出。
2. HID 普通按键可用、语音 BLE 链路未连接时，蓝牙桥不会保持虚拟音频引擎运行；启动时的输出已经被释放，所以 `audioReady=false`。
3. 「重试音频设置」调用 `applyAudioSettings`，第一道门是 `shouldKeepVirtualAudioActive`。没有 Ready 的桥、没有活跃语音、没有测试音时，该判定为 false，函数只释放输出，不调用配置，也不写日志。用户看到的重试因此是空操作。
4. 结果是页面进入时输出未 Ready，页面又没有自动配置入口；用户只能反复点一个不会执行的按钮。

页面元素、文案和 `ready_required` 门禁不是本缺陷的原因，本次不修改。

## 修复

- 新增 Onboarding 音频准备租约：用户停留在音频页且已选中受支持设备时，App 主动配置该虚拟音频输出。
- 租约只覆盖页面停留期间：蓝牙桥的状态变化、自动重连和空闲释放不能把刚配置好的输出立即释放；系统挂起仍然释放，恢复后由既有恢复路径重新配置。
- 离开音频页、完成或退出 Onboarding、App 退出时解除租约；没有语音、测试音或 Ready 的桥继续需要输出时，走既有释放路径。
- 进入音频页、设备枚举完成、重新回到前台和点击设备时都会尝试自动准备。
- 「重试音频设置」改为调用同一准备入口，不再经过会静默返回的 keepalive 门禁。
- 页面元素、文案、`audio_gate=ready_required` 和 Ready 门禁保持不变。配置成功时第三项自然显示「音频输出正常」；配置失败时才显示原有恢复卡。

## 自动化验证

运行命令与结果：

```bash
swift test --disable-keychain --filter OnboardingFlowTests
# 121 tests in 1 suite passed

swift test --disable-keychain
# 1576 tests in 113 suites passed

./scripts/test.sh
# RESULT passed=48 failed=0
```

公开模式 `swift build --disable-keychain` 和 `scripts/build-app.sh` Release App 构建通过。仓库治理检查通过。

新增或更新的覆盖：

- `VirtualAudioConnectionLifecyclePolicy` 增加 `onboardingPreparationActive`：无桥、无语音时保持输出；系统挂起时仍释放；解除租约后恢复原有释放行为。
- `OnboardingFlowTests` 锁定进入音频页、设备枚举完成、重新激活、设备选择和错误恢复都走 `prepareOnboardingAudioOutput`，离开页面走 `endOnboardingAudioPreparation`。
- 现有音频页测试继续要求设备选择和 Ready 门禁，不改变页面元素或文案。

## 真机验收

待完成：

- 使用一台普通按键 HID 可用、语音 BLE 链路未连接的小米遥控器进入音频页，确认输出自动配置、第三项「音频输出正常」自动勾选，不需要点击「重试音频设置」。
- 离开并重新进入音频页，确认租约解除后输出被释放、重新进入时再次自动配置。
- 恢复遥控器语音连接后完成真实语音文字上屏与完成页检查。

本机额外实验：直接使用 CoreBluetooth 连接系统当前已连接的同型号遥控器也出现连接超时。因此本次不把修复范围扩大到替换保存的蓝牙 identifier；本次只修复“页面进入后没有主动配置输出”和“重试空操作”。遥控器语音链路本身仍需要独立排查。

## 验证边界

- 单元测试证明生命周期策略和视图接线，不能驱动真实 CoreBluetooth 回调、HID 事件或虚拟声卡。
- 本修复不保证遥控器语音 BLE 链路一定可连接。若链路持续超时，Onboarding 会在语音测试页暴露真实连接失败；不能用音频门禁伪造语音成功。
- 真实音频首字、尾字、快速连续会话、断连恢复和第三方工具文字上屏仍按 `Testing/FirstRunOnboarding.md` 与硬件语音音频合同单独验收。
