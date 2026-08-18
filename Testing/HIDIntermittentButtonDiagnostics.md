# 实体遥控器按键偶发无响应诊断手册

## 适用范围

- 分支：`fix/bug-1.9.0-test-permission-history-hid-20260819`
- 适用版本：包含 2026-08-19 HID 分层诊断的无线麦SayAll.app 候选包
- 重点设备：小米 RC003；其他已支持实体遥控器可作稳定基线

## 测试前准备

1. 确认输入监控和辅助功能已授权，自定义按键映射已开启。
2. 为 OK 键配置一个结果明确、可重复执行的普通动作，例如回车。
3. 打开 `~/Library/Logs/RemoteMic/runtime.log`，记录测试开始时间，不要清空其他用户日志。
4. 同时确认遥控器语音键可正常开始、传输并停止，以区分 BLE 语音链路与 HID 按键链路。

## 用例 1：正常 OK 单击基线

1. 在普通文本输入框中短按并松开 OK 键 10 次，每次间隔至少 1 秒。
2. 每次应只执行一次配置动作。
3. 每次日志应依次出现可对应的 `HID REPORT accepted`、`HID EDGE pressed=ok`、`HID GESTURE button=ok` 和 `HID BUTTON button=ok`；松开时应出现 `HID EDGE ... released=ok`。

失败判定：动作缺失、重复，或日志在任意一层中断。

## 用例 2：连续使用与语音交替

1. 连续完成 20 轮“按住语音键说一句并松开 → 等待文字上屏 → 短按 OK”。
2. 交替执行方向键、菜单键和 OK 键，持续至少 5 分钟。
3. 所有按键应按现有配置执行，实体 Mac 键盘保持可用，语音链路不应因新增日志受影响。

失败判定：OK 偶发无动作、其他按键行为变化、实体键盘受阻或语音异常。

## 故障日志判读

- 没有任何新的 `HID REPORT`：报告未进入 App 的 IOHID 回调范围，优先检查真实设备、系统 HID/权限和监听生命周期。
- `HID REPORT callback_rejected`：查看 `reason` 与系统错误码。
- `HID REPORT rejected reason=...`：按原因检查监听状态、权限、位置或设备路由。
- `parse_failed`：报告到达但格式未被当前解析器接受。
- 有 `accepted`，没有 `HID EDGE pressed=ok`：解析出的 usage 没有形成新的 OK 按下边沿，检查 report 内容变化或残留按下状态。
- 有 `HID EDGE pressed=ok`，没有 `HID GESTURE`：检查手势等待、释放事件和辅助动作配置。
- 有 `HID GESTURE`，没有 `HID BUTTON`：检查动作执行前置条件或 `HID ACTION failed`。
- 有 `HID BUTTON button=ok` 但界面无结果：HID 链路已执行到动作层，应转查目标 App、辅助功能注入和前台焦点。

## 稳定功能回归

- RC003 普通方向、返回、菜单、主页、TV 和音量键。
- 单击、双击、长按及允许连发的方向键。
- 遥控器语音 `STREAM_START → AUDIO → STREAM_STOP`。
- MacBook 实体方向键与普通键盘输入。
- 断连、重连、权限关闭后重新授权。

## 日志与隐私

提交完整 `runtime.log`，并注明故障发生的本地时间、按键、预期动作、实际结果、遥控器型号以及当时语音是否正常。诊断日志不包含原始 HID payload、设备指纹、蓝牙地址、输入文字或语音内容。

## 验证边界

自动化和私有模拟能够验证代码分层与既有行为回归，不能替代真实 RC003 固件、macOS IOHID 回调、输入监控/辅助功能权限历史和目标 App 行为。只有真机再次出现故障并获得分层日志后，才能确认精确根因与正式行为修复。
