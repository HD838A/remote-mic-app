# 空闲释放后后台恢复重新占用虚拟音频

## 状态与范围

候选修复。覆盖 macOS 宿主的空闲释放、音频恢复、系统恢复和连接就绪预热。真实 CoreAudio 断言、遥控器首字与尾字仍待现场验收。

开发基线为 `origin/main` 的 `9f384bf93185007cead692b6f1f02004e5842ca1`。

## 错误证据与日志边界

用户提供的性能报告记录 build 285 在空闲释放后约几十秒重新持有音频断言。后续 build 320 的占用比例降低，仍有回占记录。本次收到的是汇总报告，缺少原始电源流水和对应的解密运行日志，不能确认每次回占的具体调用者。

生产策略的最小回放可以重复观察到同一缺口。输入保持一台 ready 遥控器、没有语音或测试音、系统未挂起。空闲超时传入 `idleBridgeReleaseDue=true` 时，`shouldBeActive` 返回 false。下一次普通恢复使用默认参数，返回 true。

## 根因假设与实验

- H1 为瞬时空闲标记。支持证据为释放入口只在当次调用传入标记，恢复入口没有保留该状态。最小策略回放确认该缺口。
- H2 为播放器停止但健康判断仍为真。当前健康缓存已检查 `playerPlaying` 和设备绑定，不能解释本次门禁缺失。
- H3 为正常系统唤醒或用户明确请求。原有逻辑确实允许这些入口重新配置，但报告没有逐次触发证据。本次仅限制已空闲释放后的后台活动，保留真实音频与用户明确请求。

修复前增加 `idleReleaseStateIsSharedByTimeoutAndBackgroundRecovery`。接线回归出现三项失败断言，确认原实现缺少持续状态及后台请求分类。该测试属于源码接线检查，运行时策略回放承担行为证据。

## 修复

- 排空开始前保存进程内空闲释放状态。状态持续参与系统恢复和遥控器 ready 判定。
- 硬件与引擎恢复、蓝牙和 Chromecast 连接预热按后台请求处理。延迟恢复任务在执行时重新判断，忽略后记录唯一 `result=ignored` 终态。
- 真实语音、测试音和用户明确的音频设置操作解除门禁。配置失败仍可使用原有恢复路径，退出时清除状态。
- 活跃音源和仍待播放的尾包保留恢复资格。继续使用现有异步配置、配置期 PCM 缓存、generation 取消和自然排空。
- 沿用 `AUDIO RELEASE` 的请求、取消和完成记录。新增 `AUDIO IDLE phase=activation_requested|activation_ignored` 与 `idle_released` 字段，区分恢复请求与输出真正就绪。字段仅包含固定原因码、布尔状态和计数。

## 自动化与现场边界

本次清空私有组件与硬件模拟环境变量，以公开兼容模式验证。

- `swift test --disable-keychain --filter 'AudioConfigurationChangeRecoveryTests|VirtualAudioConnectionLifecycleTests|CoreVoiceInputJourneyTests|ATVVProtocolTests|VoiceFnTapSessionControllerTests|BluetoothLifecycleTests'` 通过，7 组共 124 项。
- `swift test --disable-keychain` 通过，100 组共 1,390 项。
- `swift build --disable-keychain -c release` 通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 zsh scripts/test.sh` 通过，48 项。
- 显式设置 `SAYALL_TEST_VIRTUAL_AUDIO_CONFIGURATION=1`，执行 `swift test --disable-keychain --skip-build --filter 'VirtualAudioConnectionLifecycleTests/installedVirtualOutputPreservesFirstPlaybackAfterQueuedPlayerRestart'` 通过。本机真实 `SayAll` 虚拟声卡的三次播放均观察到合成信号，正常排空、中断样本为零。
- 仓库治理、边界、修改文档相对链接和 `git diff --check` 通过。

新增测试覆盖持续空闲、重复后台事件、明确请求、失败重试、排空期间再次按下、待播尾包，以及“空闲释放 → 目标延迟就绪 → 首次语音配置缓存 → 松键尾包 → 单次完整 Fn 会话”。回环测试只证明真实虚拟输出播放，不涉及实体遥控器或第三方工具文字上屏。

测试手册见 [Mac 自动休眠时释放虚拟音频测试](../Testing/MacIdleSleepAudioRelease.md)。实机还需覆盖空闲释放后至少三分钟无回占、系统唤醒和设备变化、RC003 第一次完整短句、快速连续两句、断连恢复与目标语音工具文字上屏。

本次不以策略测试或构建推断真实电源管理结果。修复保持候选状态，直到适用现场用例通过。
