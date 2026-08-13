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
- 无私有组件与注入私有组件两种源码测试配置均可编译；宿主测试直接验证未注入时组件不可用、权限受限且启动失败关闭；
- 未注入私有组件的定向测试 52 项通过，注入私有组件的适配层定向测试 20 项通过，完整公开配置 `swift test` 225 项通过；
- 私有硬件模拟集成 22 项和 Self Test 42 项通过；模拟覆盖 DJI 标准输入、断线新代次、旧 buffer 拒绝及 RC001/RC003 稳定基线；
- 本轮没有构建 App、签名、公证、打包或发布，也没有重新执行真实 DJI 硬件流程。

历史验证记录：此前隔离测试包曾完成 DJI Mic Mini 选择、16 kHz 单声道启动、`MiRemoteV 2ch` 双声道非零回读和关闭停止；本轮许可边界调整后没有重新构建或运行该产物，不能把历史结果当作当前分支的产物验收。

模拟硬件覆盖统一 Int16 PCM 边界、断连重连事件和旧 generation fixture；它不直接驱动生产 AUHAL callback。短时真机回读也不能替代闪电说、听歌、AirPods、抢占、断连、睡眠和长时间人工验收。
