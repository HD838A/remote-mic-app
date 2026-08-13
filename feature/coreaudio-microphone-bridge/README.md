# 通用 CoreAudio 麦克风桥接

- 状态：自动化与短时真机链路已通过，等待完整人工验收
- 目标：将 DJI Mic Mini、Mac 内建麦克风及未来标准 CoreAudio 输入统一送入 `MiRemoteV 2ch` 等虚拟麦克风。

用户在音频设置中选择输入设备并显式开启持续桥接。RC003、Nearby iOS 或手机网页版语音开始时会暂时抢占，结束后恢复持续输入。应用不主动修改 macOS 默认输入、默认输出或系统输出。

本功能不包含 DJI 型号专用驱动，也不承诺蓝牙直连按钮。AirPods 并发、长时间稳定性、休眠重连和最终闪电说转写仍需真机验收。音频只在内存中转换和转发，不落盘、不上传。

通用采集实现位于 GetSayAll 私有 `sayall-audio-input-kit`，本仓库只保留 GPL 宿主适配与来源仲裁。未注入私有组件时该实验功能失败关闭；在组合二进制的 GPL 分发边界解决前不得打包或对外发布。

实现使用 input-only AUHAL 按 UID 绑定输入，以预分配缓冲槽接收原生 PCM，串行转换为 16 kHz 单声道 Int16，并复用现有 `VirtualAudioOutput`。功能配置缺失时默认关闭，输入输出 UID 相同时拒绝启动。

详细开发记录见 [development.md](development.md)，人工验证见 [testing.md](testing.md) 和 [Testing 手册](../../Testing/CoreAudioMicrophoneBridge.md)。详细研究保存在私有资料库 `projects/remote-mic-app/research/dji-mic-mini-coreaudio/v1/README.md`。
