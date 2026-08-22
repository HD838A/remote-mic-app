# Right Option Hold 测试手册

## 适用范围

- 分支：`feature/voice-option-scroll-events`
- 功能：RC003 麦克风键的 Right Option Hold 模式
- 本手册不覆盖尚未实现的 Scroll Wheel Event 映射

## 测试前准备

1. 使用 macOS 14 或更高版本，准备 RC003 小米蓝牙语音遥控器、无线麦 SayAll.app 和 Mac 微信。
2. 确认无线麦已获得蓝牙权限；本功能还需要“辅助功能”权限。
3. 在 Mac 微信中打开一个可以使用按住说话的聊天窗口，先不要发送测试内容。
4. 保留默认 Fn/Globe 模式作为回归基线；不要在同一轮测试中开启 Typeless Fn 点按模式。

## 自动化验证边界

- `KeyboardInjector` 单元测试验证右 Option 虚拟键码、keyDown/keyUp 和权限门禁。
- `AppSettings` 单元测试验证模式导入导出，以及旧配置缺少 `voiceKeyMode` 时回退 Fn/Globe。
- 设置页回归测试验证模式选择器和绑定入口仍位于按键映射页。
- 自动化不能证明 macOS 微信实际收到 Right Option，也不能替代真实 RC003、系统权限或第三方 App 验收。

## 用例 1：默认 Fn/Globe 回归

1. 启动无线麦，进入“按键映射”。
2. 将“语音键模式”设为“Fn/地球键”，关闭“语音键模拟 Fn 点按”。
3. 在支持 Fn 长按的语音输入工具中按住 RC003 麦克风键并说话。
4. 松开麦克风键。

预期：语音开始和结束行为与原版本一致；不出现 Right Option 卡住；应用日志没有 `VOICE RIGHT_OPTION` 事件。

失败判定：默认模式无法开始/结束语音、Right Option 保持按下，或原有 Fn/Globe 行为改变。

## 用例 2：Mac 微信按住说话

1. 在“按键映射”中选择“右 Option 长按”。
2. 如果系统弹出辅助功能授权提示，允许无线麦，并完全退出后重新启动应用。
3. 切换到 Mac 微信聊天窗口。
4. 按住 RC003 麦克风键，确认微信进入按住说话状态。
5. 保持按住状态说一句话。
6. 松开 RC003 麦克风键。

预期：按下后开始录音，松开后结束录音并由微信自动发送；一次按住/松开只产生一组 Right Option keyDown/keyUp。状态不会在松开后继续显示按下。

失败判定：微信未进入按住说话、松开后仍在录音、松开后没有发送、一次操作重复发送多组事件，或应用退出后 Option 仍保持按下。

## 用例 3：断连与退出清理

1. 选择“右 Option 长按”。
2. 按住 RC003 麦克风键后断开遥控器，或在按住状态退出无线麦。
3. 重新连接遥控器并启动无线麦。

预期：应用先发送 Right Option keyUp 或完成等价清理；系统和微信不会残留 Option 按下状态。重新连接后可再次正常按住说话。

失败判定：Mac 后续输入持续表现为按住 Option，或新会话无法发送成对的按下/释放事件。

## 日志收集

在测试后通过 SayAll.app 菜单栏菜单打开日志目录，收集不含个人语音内容的相关日志。重点查找：

- `VOICE RIGHT_OPTION DOWN`
- `VOICE RIGHT_OPTION UP`
- `VOICE RIGHT_OPTION ... failed`
- `VOICE STREAM_START` / `VOICE STREAM_STOP`

请同时记录 macOS 版本、SayAll.app 版本/分支、辅助功能授权状态、RC003 是否真实连接、微信版本和具体失败用例。不要上传包含账号、令牌或聊天内容的日志。

## 尚未完成的验收

在自动化测试和本机构建完成前，Right Option Hold 仍不能标记为真实环境通过。真实 RC003 + Mac 微信的按住说话用例需要在用户机器上执行；Scroll Wheel Event 必须等待本功能验收成功后再进入第二阶段。
