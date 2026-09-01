# macOS 自带听写真机测试

## 适用范围

本手册适用于新增的 macOS 听写触发模式。安装包必须由项目正式签名和公证流程生成，未签名的本地构建不能作为用户交付包。

## 测试前准备

1. 使用小米 RC003，并确认普通按键和语音键都能被无线麦识别。
2. 在 macOS 系统设置中开启听写，选择需要的语言，把快捷键设为“连按两下 Control 键”。
3. 在无线麦中选择 `MiRemoteV 2ch`，确认测试音正常。
4. 给无线麦开启蓝牙、输入监控和辅助功能权限。
5. 在“按键映射”页保持“Fn/地球键”，关闭“语音键模拟 Fn 点按”，再开启“使用 macOS 自带听写”。
6. 打开一个普通文本输入框，确保光标正在闪烁。测试期间不要碰 Mac 键盘。

首次开启后，如果遥控器型号尚未确认，无线麦可能短暂重新连接一次。必须等连接恢复后再开始用例；不把第二次按语音键才成功视为通过。

## 用例一 直接按住说话

1. 按住遥控器语音键。
2. 说“无线麦已经连接成功”。
3. 松开语音键。

预期结果是听写自动启动，松开后自动结束，输入框出现完整文字。开头的“无线麦”和结尾的“成功”都不能丢失。开场双击后会先播放约 250 毫秒静音，给系统听写留出启动时间。整个过程不需要按 Mac 键盘。

以下任一情况都算失败。

- 没有出现听写状态或文字。
- 需要手动连按两下 Control 才能开始或结束。
- 开头、尾音或整句被截断。
- 松开后听写仍保持开启，或稍后又被反向打开。
- Control 像被持续按住一样影响后续键盘操作。

## 用例二 很快按下并松开

1. 快速按下语音键并立即松开。
2. 等待两秒，再正常完成一次用例一。

预期结果是短会话能够自行清理，下一次正常听写仍能一次成功。短会话不能留下持续按住的 Control，也不能让下一次操作从“结束听写”开始。

## 用例三 连续会话

连续完成二十次用例一，每次看到文字提交后立即开始下一次。至少包含一次一秒以内的短句和一次十秒左右的长句。

预期结果是二十次都由同一枚遥控器语音键完成。不同会话的开头音频不能串到下一次，松开后也不能漏掉尾音。

## 用例四 断连与权限变化

1. 听写进行中关闭遥控器或让它断开，随后重新连接并再测一次。
2. 关闭无线麦的辅助功能权限，再按一次语音键。
3. 恢复权限，重新开启 macOS 听写模式并再测一次。

预期结果是中断能够结束当前会话，恢复后可以重新使用。权限缺失时应停止软件触发并给出可执行的权限提示，不能发送半个 Control 事件，也不能静默卡死。

## 稳定功能回归

- 关闭 macOS 听写模式后，默认 Fn 长按路径保持原样。
- Typeless 的 Fn 点按仍在开始和结束时各发送一次 Fn 点按。
- 左 Command 和右 Command 模式保持原样。
- 普通遥控器按键的单击、双击、长按和自定义快捷键不变。
- iPhone、Apple Watch 和网页版语音入口不受这个仅面向实体蓝牙遥控器的开关影响。

## 日志收集

复现后保留 `~/Library/Logs/RemoteMic/runtime.log`。正常实体遥控器会话应包含以下同一 `trace` 的记录。

```text
VOICE TAP trace=<n> phase=start_requested trigger=macos_dictation result=submitted diagnostic_boundary=macos_dictation_text_unobservable
VOICE TAP trace=<n> phase=start_accepted trigger=macos_dictation result=accepted diagnostic_boundary=macos_dictation_text_unobservable
ATVV AUDIO routed trace=<n> ... route=macos_dictation accepted=true
VOICE TAP trace=<n> phase=stop_requested trigger=macos_dictation result=accepted diagnostic_boundary=macos_dictation_text_unobservable
VOICE TAP trace=<n> phase=external_boundary trigger=macos_dictation result=unobservable expected_effect=dictation_text_in_focused_field diagnostic_boundary=macos_dictation_text_unobservable
```

`result=submitted` 只表示无线麦准备提交开始请求，`result=accepted` 只表示点按状态机已经接收。`external_boundary` 仅在关闭 Control 双击完整结束后记录，并明确表示系统听写是否生成文字仍需人工观察，不能把该日志当成文字已经出现。

若出现 `phase=failed`、`start_tap_failed`、`stop_tap_failed`、HID 中和失败或权限变化，请连同发生时间和具体操作一起记录。日志不得包含说话内容、转写文字、设备 UUID 或用户文件路径。

模式关闭、权限撤回、断连或 App 退出时，同一 `trace` 应出现一次 `phase=cancelled result=completed reason=...`。按键注入失败时，同一 `trace` 应先出现 `phase=failed`，清理后再出现 `phase=recovery result=completed|failed target=hardware_fn`；不得同时把同一段记成正常 `external_boundary`。首次通用名称设备的正常顺序应是 `BLE MODEL identified=rc003`、`BLE READY`、再到 `ATVV STREAM accepted ... model=rc003`，不能先出现 `unsupported_remote_model` 再靠第二次按键成功。

## 验证边界

自动化负责检查 Control 边沿、双击顺序、开头缓存、尾音排空、中断清理、配置迁移和旧路径回归。源码检查和模拟音频不能证明 macOS 听写真正接受合成按键。最终验收必须使用项目正式签名版本、真实 RC003、真实系统听写和可编辑输入框完成上述用例。
