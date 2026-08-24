# 千问模式残留右 Command，并误触发 VoiceOver

- 时间：2026-08-25
- 状态：候选修复完成，等待真实 RC003 与千问验收
- 影响范围：macOS；开启千问兼容模式的 RC003 用户
- 功能点：HID 语音键屏蔽、ATVV 语音生命周期、右 Command 注入

## 用户反馈与现场证据

1. 松开语音键后，千问仍显示组合输入蓝线，需要再点对勾才能结束。
2. 随后点击 Dock 图标会在 Finder 的 Applications 中定位 App，符合 Command 仍被视为按下时的系统行为。
3. 长按语音键会打开 VoiceOver；关闭后再次长按仍会出现。
4. 运行日志同时确认 RC003 已产生 `STREAM_START → AUDIO → STREAM_STOP`，音频缓冲成功写入并排空，因此问题不在遥控器固件、BLE 音频结束或 MiRemoteV 写入。
5. 千问在“系统默认”麦克风配置下仍使用内置麦克风；在千问内明确选择 `MiRemoteV 2ch` 后输入设备正确。

## 根因

RC003 的实体语音键是 F5。旧候选版把该 HID usage 直接改成右 Command，因此实体按键报告与修改键生命周期耦合：长按时可能形成 macOS 的 Command-F5，触发 VoiceOver；结束路径未可靠产生独立的右 Command key-up，又会留下全局 Command 状态，导致千问不结束及 Dock 点击异常。

另外，临时修改 macOS 系统默认输入不能改变千问已经缓存或明确选择的输入设备，因此不应作为兼容方案。

## 最小修复

1. 千问模式把 RC003 实体 F5 映射为 usage `0`，不再直接映射成右 Command。
2. ATVV 开始时由 SayAll 单独发送右 Command key-down；ATVV 停止后先等待尾音排空，再发送 key-up。
3. 快速重按以会话代次隔离旧排空回调；断连、关闭模式和退出立即释放按键。
4. 千问模式只自动选择 SayAll 的 `MiRemoteV 2ch` 输出，不再修改系统默认输入；千问自身需明确选择 `MiRemoteV 2ch`。

## 自动化与人工边界

- 自动化覆盖：F5 屏蔽、右 Command 单次按下、尾音排空后松开、快速重按、断连/关闭/退出强制释放，以及系统默认输入不再由千问模式管理。
- 待人工验收：真实 RC003 短按和长按均不打开 VoiceOver；千问松开后自动结束；Dock 点击正常；千问实际读取 `MiRemoteV 2ch`。
