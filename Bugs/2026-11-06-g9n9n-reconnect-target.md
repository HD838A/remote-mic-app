# G9N9N 连接页重连指向错误后端

## 现场现象与证据

用户报告焦点在 Mac、使用 Deskflow 时，G9N9N 录音键无反应；本机空白文稿测试未出现豆包浮窗。
本地 build 18 界面仍显示 G9N9N 已连接、语音已就绪。

09:33 的旧会话有 109,568 个样本正常排空，软件 Fn 边沿提交成功、目标工具响应 unknown；
不能将该旧会话作为后续失败测试的成功证据。最新测试没有新增语音会话，缺少新的 ATVV 控制/PCM。
豆包可见设置保持 Fn 长按、SayAll 麦克风及全局语音开启。

09:43 agent 点击连接页“立即重新连接”，运行日志却记录
`remote_model_family=xiaomi reason=reconnecting`，未出现 G9N9N 身份读取或能力协商。
源码确认：该按钮调用 `BridgeAppModel.reconnect()`，原实现只操作小米桥；
真正的 Chromecast/G9N9N 恢复入口为 `reconnectChromecast()`，只由首次设置调用。

因此已确认的是“所选 G9N9N 无法通过连接页重连”，不是已证明豆包 Fn 故障或原始语音失效根因。

## 最小修复

`BridgeAppModel.reconnect()` 在已启动且所选档案属于 Chromecast family 时，调用原有
`reconnectChromecast()` 并结束；其他档案沿原路径。复用已有公共 G9 重连隔离、DIS 准入、
通知订阅与能力协商，以及现有 HCI 显式重试，不重置 TCC、系统配对或驱动。
请求只在现有有界 AppLogger 中写一次来源，不新增逐包或音频转储。

## 验证与边界

- 自动化：运行公开全量 `swift test --disable-keychain --jobs 4`；1,287 项 / 93 套件全部通过（测试阶段 58.8 秒）。治理、Markdown 相对链接及 diff 检查通过。
- 实机：build 19 点击同一连接页按钮，约1秒完成 G9 断开/重新准入/能力就绪及新鲜身份，未再次要求 HCI 认证；第一句能上屏，第二句另有状态缺陷，见 [第二次语音记录](2026-11-06-g9n9n-second-voice-session.md)。
- 语音恢复仍须真实短句和最终文字，不能用重连、采集或队列 passed 代替。
- HYPC 的跨机语音路由是另一项功能，本修复不加入网络转发、不修改 Deskflow 或 Windows。
