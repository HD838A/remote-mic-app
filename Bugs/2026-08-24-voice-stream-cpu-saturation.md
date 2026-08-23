# 语音流期间进程 CPU 接近占满单核

- 时间：2026-08-24
- 状态：候选修复完成；自动化、项目自检与 Release App 验证通过，等待真实 RC003 性能对照
- 影响范围：包含首次使用引导的 macOS 版本；打开过设置或引导窗口后进行蓝牙、手机、Watch 或网页语音的场景
- 功能点：语音样本状态、SwiftUI 模型观察、Onboarding 语音门禁
- 简单描述：每个音频批次都会发布一次只供 Onboarding 判断“是否收到过样本”的全局状态，导致大型设置视图在语音期间以约 60 Hz 被无效化。
- 原始记录：安全与性能审计记录的 299 秒语音约消耗 301 秒进程 CPU；本机 `~/Library/Logs/RemoteMic/runtime.log`

## Observations

- 原始审计测得空闲期约 0.71% CPU，语音期接近占满一个核心，但没有保留可直接关联当前 `main` 的 Time Profiler trace。
- 当前安装的 `1.9.8 (131)` 与仓库版本元数据一致。最近一次真实 RC003 运行包含 12 个会话、91.820 秒、5,851 个音频批次和 1,404,240 个样本，平均约 63.72 批/秒，每批固定 240 个样本。
- `XiaomiBluetoothBridge` 使用 CoreBluetooth 主队列；每批解码完成后会在同一主线程调用 `BridgeAppModel.bluetoothBridge(_:didDecode:)`。
- 旧实现每批都累加 `@Published currentVoiceSampleCount`。该属性唯一的消费方是 Onboarding，且只判断数值是否大于零，不显示实时样本数。
- `RemoteMicRootView` 与其子级 `SettingsView` 同时观察整个 `BridgeAppModel`。根视图本身不读取任何模型发布属性；设置窗口关闭后，其 controller 仍由 App delegate 保留。
- 蓝牙路径已有独立的 `bluetoothVoiceDecodedBatchCount` 和 `bluetoothVoiceDecodedSampleCount`；移动语音路径已有 `mobileVoiceAudioBatchCount` 与 `mobileVoiceAudioSignalMetrics.sampleCount`。删除展示用累计值不会损失现有诊断计数。

## Hypotheses

### H1：逐批 `@Published` 更新造成 SwiftUI 无效化风暴（ROOT CAUSE）

- Supports：日志确认真实 RC003 约每秒产生 63 个批次；代码确认每批同步修改全局 `ObservableObject`；至少根视图和当前页面同时订阅该对象；唯一 UI 需求只是每个会话首次收到样本时切换一次布尔状态。
- Conflicts：没有当前候选构建的 Time Profiler A/B 数据，尚不能量化该路径占原始约 100% CPU 的具体比例。
- Test：用确定性回归驱动 4,000 个连续批次，要求一个会话只允许一次“收到样本”发布；再用同机 Release 构建和真实 RC003 比较修复前后 CPU 与调用树。

### H2：逐批音频 buffer 分配与 DSP 是主要热点

- Supports：当前每批都会创建 `AVAudioPCMBuffer`，ADPCM、平滑和增益也会分配数组。
- Conflicts：总输入仅为 16 kHz 单声道，当前没有调用树证明这些工作足以单独占满核心；引入 buffer pool、Accelerate 或后台音频队列会明显扩大音频生命周期和线程安全范围。
- Test：先完成 H1 的 Release A/B。如果去除视图无效化后 CPU 仍异常，再根据 Time Profiler 单独调查，不在本修复中推测性重构音频路径。

## Experiments

1. 解析最近 100 个现场 RC003 会话：45,100 个批次 / 722.389 秒，平均 62.43 批/秒、每批 240 个样本。
2. 解析最近一次 `1.9.8 (131)` 真实运行：12 个会话平均 63.72 批/秒，所有会话 `enqueue_failures=0`，证明批次频率不是入队失败重试造成的。
3. 全仓库查找 `currentVoiceSampleCount`：只有 Bridge 模型的两个音频入口、两个会话重置点和 Onboarding 一个消费者。
4. 检查视图所有权：`RemoteMicAppDelegate` 持有模型，`RemoteMicRootView` 无需通过 `@ObservedObject` 维持其生命周期。
5. 最小策略回归连续输入 4,000 个非空批次，只产生一次展示状态转换；会话重置后下一批可以再次转换。

## Root Cause

Onboarding 为验证“当前语音会话是否收到过任意样本”引入了累计样本数，并把它放在大型共享 `BridgeAppModel` 的 `@Published` 表面。RC003 每约 15.6 毫秒产生一个音频批次，因此一个只需要每会话变化一次的布尔事实，被放大为约 60 Hz 的全局模型发布。根视图又重复观察同一个模型，进一步扩大了 SwiftUI 求值范围。

## Fix

- 将展示状态改为 `hasReceivedCurrentVoiceSamples`，会话开始时重置，只在首个非空批次时发布 `true`。
- 蓝牙、Nearby iPhone、Watch 和 Web 音频入口共用同一发布门禁；后续音频批次不再触发该 `@Published` 属性。
- Onboarding 订阅布尔状态并使用 `removeDuplicates()`，原有来源校验和语音步骤门禁保持不变。
- `RemoteMicRootView` 改为普通持有模型，只继续观察决定根页面分支的 `AppSettings`。
- 保留所有音频解码、入队、批次数、样本数、信号指标、尾部诊断和日志行为；不修改 buffer、DSP、CoreBluetooth 或音频线程。

## Validation

- `swift test --filter 'OnboardingFlowTests|ATVVProtocolTests|BluetoothVoiceTailDiagnosticsTests'`：通过，42 个测试、0 失败。
- `swift test`：通过，341 个测试、0 失败。
- `./scripts/test.sh`：通过，42 项、0 失败。
- `./scripts/build-app.sh`：Apple Silicon Release App 构建通过。
- `./scripts/verify-app.sh dist/SayAll.app`：App 结构、资源与签名自检通过。
- 新增回归覆盖：空批次不发布、一个会话连续 4,000 个批次只发布一次、重置后的下一会话可以再次发布、蓝牙和移动音频都经过同一门禁、根视图不再重复观察整个模型。
- `Testing/FirstRunOnboarding.md` 已增加设置页可见、窗口关闭和 Onboarding 语音测试页三种状态下的 30 秒 CPU / Time Profiler 对照步骤。
- 构建仅出现仓库既有的 macOS 14 `onChange(of:perform:)` 弃用警告，与本修复无关。

## Validation Boundary

- 自动化已经证明逐批全局发布被消除，并证明 Onboarding、ATVV 解码和尾部诊断基线未改变。
- 尚未用候选 Release 构建和真实 RC003 重新采集 30 秒 CPU 与 Time Profiler，因此不能把原始约 100% CPU 直接改写为当前候选的实测数值。
- 合入前应在同一台 Mac、同一虚拟音频设备上分别测试设置窗口可见、打开后关闭以及 Onboarding 语音测试页；确认进程 CPU 明显下降，且 `batches`、`samples`、`enqueue_failures`、最终排空和文字输入结果保持正常。
