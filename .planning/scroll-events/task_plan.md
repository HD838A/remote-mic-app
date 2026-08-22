# Codex 滚动事件映射

## 目标

为遥控器按键增加 macOS Scroll Wheel Event 动作，可用于 Codex、ChatGPT 等应用的长回复上下滚动；保留现有按键映射和语音功能。

## 阶段

- [completed] 1. 分析动作枚举、映射 UI、事件注入和重复按键架构
- [completed] 2. 实现滚动动作与映射显示
- [completed] 3. 增加回归测试并验证动作参数
- [completed] 4. 构建、安装、重启并完成提交

## 成功标准

- 映射列表可以选择“滚轮上 / 滚轮下”动作。
- 触发一次遥控器按键会发送 macOS scroll wheel event，而非键盘方向键。
- 连续按键能够稳定重复滚动，不影响现有语音、Command-Tab 和方向键功能。
- 自测通过，Release 应用构建和校验通过，安装后的 SayAll 可启动。

## 遇到的错误

暂无。
