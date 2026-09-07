# 本地移植：减少语音样本引起的界面刷新

- 来源：上游 `7fc8851`；本地基线 `e464c52`。
- 上游现场记录 RC003 每秒约 63 批音频；本地代码也逐批发布 `currentVoiceSampleCount`，但唯一消费者只判断是否大于零。未在本机测量 CPU 占比，不能承诺具体降幅。
- 移植：改为每个逻辑会话只发布一次收到样本的布尔状态，保留独立诊断计数；根视图不重复观察模型。续接不重置逻辑会话，也不改变 PCM 和倒计时。
- 修改前现有 Swift 测试：192 项通过。
- 修改后 `swift test --disable-automatic-resolution`：192 项通过；`git diff --check` 通过。真实 CPU 对照边界见 `Testing/LocalAudioOptimizations.md`。
