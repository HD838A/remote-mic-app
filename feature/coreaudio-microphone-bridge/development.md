# 开发记录

## 接入点

- 私有 `GetSayAll/sayall-audio-input-kit`：input-only AUHAL、权限、格式转换、设备监听和实时有界缓冲。
- `CoreAudioInputSource.swift`：GPL 宿主的薄适配层与高优先级来源仲裁，不保存私有采集实现。
- `AudioOutput.swift`：通用输入枚举及持续输入队列上限。
- `BridgeAppModel.swift`：生命周期、路由恢复与 RC003/手机抢占。
- `AppSettings.swift`、`SettingsView.swift`：默认关闭的开关、输入 UID、设备卡和状态。
- `Info.plist`、`RemoteMic.entitlements`、构建脚本：麦克风权限与签名。
- `CoreAudioInputSourceTests.swift`、`HardwareSimulationIntegrationTests.swift`：门禁、仲裁和 DJI 模拟场景。

## 关键决策

- 使用通用 CoreAudio 输入抽象，不根据 DJI 名称创建专用驱动。
- 私有组件通过 `SAYALL_AUDIO_INPUT_KIT_PATH` 作为开发依赖注入；未注入时功能失败关闭，不影响 RC001/RC003 稳定路径。
- 无线麦是 GPL-3.0 派生项目。私有组件与其链接后的组合二进制在完成许可证评估前不得打包或对外分发；拆分仓库不改变该义务。
- 使用 input-only AUHAL，避免隐式打开 DJI 输出或依赖系统默认输入。
- 第一版使用有界 push 队列；真机长时间数据若显示持续漂移，再升级为输出时钟拉取和动态速率补偿。
- 高优先级语音结束时先完成对应输出会话清理，再解除抢占并恢复持续输入，避免恢复后的首批 buffer 被旧会话清除。
- 输入 render 或转换失败会进入既有音频恢复调度，重新按 UID 枚举、读取格式并建立新会话；真实 HFP 格式变化仍需真机验收。
- 真机验证发现直接采用 AUHAL 返回的完整原生 ASBD 会让 DJI 在首个 render 失败；最终实现保留已验证的设备 nominal sample rate，并只从输入流读取真实声道数，再配置 Float32 客户端格式。该调整兼顾 DJI 稳定路径与多声道输入，下游仍统一下混和重采样。
- 不自动修正系统默认路由，只提示用户检查。

## 验证边界

私有组件抽离后已验证：

- `sayall-audio-input-kit` 独立测试 2 项通过；
- 无私有组件与注入私有组件两种配置均可构建，宿主门禁/仲裁 4 项通过；
- 两种配置的完整 `swift test` 都在既有 `DeepSeekCredentialStore` Keychain 系统调用处停滞，调用栈一致，未发现与新音频线程有关；本轮因此不把完整套件记为通过。
- 本轮没有构建 App、签名、公证、打包或发布，也没有重新执行真实 DJI 硬件流程。

已通过：

- CoreAudio/Fn 定向测试 15 项、Self Test 42 项；
- 跨仓库模拟集成 15 项、模拟器仓库 26 项；
- Release App 构建、ad-hoc 签名、麦克风 entitlement、plist 与 App 结构校验；
- 最终测试包 UI 可枚举并选择 DJI Mic Mini，AUHAL 以 16 kHz 单声道启动；`ffmpeg` 从 `MiRemoteV 2ch` 回读到双声道非零电平；关闭后资源停止。

模拟硬件覆盖统一 Int16 PCM 边界、断连重连事件和旧 generation fixture；它不直接驱动生产 AUHAL callback。短时真机回读也不能替代闪电说、听歌、AirPods、抢占、断连、睡眠和长时间人工验收。
