# 电源键微信语音消息测试手册

## 功能边界

- 分支：`feature/voice-option-scroll-events`
- RC003 麦克风键：保持原有 Fn/Globe 或语音转文字行为，不做修改。
- 遥控器电源键：选择“微信发语音消息（按住右 Option）”后，按下发送 Right Option keyDown，松开发送 Right Option keyUp。
- 此功能依赖 SayAll 的自定义按键映射和辅助功能权限。

## 配置

1. 打开 SayAll 的“按键映射”，启用“自定义按键控制”。
2. 选中“电源”按键的“单击”动作。
3. 选择“微信发语音消息（按住右 Option）”。
4. 在微信快捷键设置中保持“发语音消息”为“按住右 Option”。
5. 不要修改“语音输入文字”的 Fn 快捷键；RC003 麦克风键仍用于原有语音转文字流程。

## 实机验收

1. 打开微信聊天窗口。
2. 按住遥控器电源键并说话。
3. 松开电源键。

预期：按住期间微信进入语音录制，松开后结束录音并自动发送；电源键的一次操作只产生一组 Right Option 按下/释放事件。

回归检查：按住 RC003 麦克风键时，仍然只触发原来的 Fn/语音转文字功能，不因为新增电源键动作而改变。

## 豆包输入法边界

如果豆包输入法全局监听 Right Option，它仍可能收到 SayAll 发出的同一个系统 Right Option 事件。电源键改造只消除了“RC003 麦克风键同时触发 Fn 语音转文字”的重叠，不能从系统层面阻止另一个全局监听器接收 Right Option。若仍出现文字插入，需要在豆包中关闭 Right Option 快捷键或临时退出豆包后复测。

## 日志

重点查看：

- `POWER WECHAT RIGHT_OPTION DOWN`
- `POWER WECHAT RIGHT_OPTION UP`
- `HID HOLD button=power phase=press`
- `HID HOLD button=power phase=release`

断连或退出时还应看到 `reason=reset` 的释放日志，且不能留下 Option 长按状态。
