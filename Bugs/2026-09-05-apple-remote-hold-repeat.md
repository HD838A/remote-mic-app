# Siri Remote 按住返回键不连续删除

## 复现

- 设备：Apple Siri Remote A2854。
- App：1.9.19（172）本地候选构建。
- 配置：返回键单击映射为 `deleteBackward`，未配置双击或长按动作。
- 操作：在可编辑文字区域按住返回键超过 1 秒。
- 错误行为：只删除一个字符；RC001/RC003 在相同配置下会持续删除。
- 正常边界：配置了双击或长按动作时不能启动单击连发；不可重复的快捷键、打开 App、组合命令等动作也不能连发。

## 现场日志

2026-09-05 11:26（本地时间）的真实 A2854 日志显示：

```text
APPLE REMOTE CONTROL phase=began control=back sequence=5
APPLE REMOTE BUTTON phase=completed result=submitted button=back trigger=singleClick action=deleteBackward
APPLE REMOTE CONTROL phase=ended control=back sequence=6
```

按下到释放约 1.34 秒，期间只有一次 `deleteBackward`，证明硬件按下/释放边沿完整，缺失发生在宿主持续按压路由，而不是遥控器提前释放。

同一现场还确认 Siri 语音期间仍可产生触摸操作：Siri 键已开始收音后，日志继续出现 `APPLE REMOTE TOUCH operation_id=18 phase=started`。这会造成说话时的误移动、误滚动或误点击风险。

## 根因

`HIDRemoteMonitor` 为 RC001/RC003 实现了独立的按住连发计时器：350 ms 后开始，返回键每 50 ms，方向键和音量键每 100 ms。Siri Remote 的 `BridgeAppModel.handleAppleRemoteButton` 只接入了单击、双击和长按识别，无次级手势时执行一次单击后直接返回，没有启动或取消对应的 repeat timer。

触摸路径只在方向环/中心实体按压时抑制当前接触，没有读取 Siri Remote 语音会话状态，因此语音按住期间的触摸仍会提交到指针控制器。

## 修复

- Siri Remote 复用 RC001/RC003 的 `HIDRemoteTiming` 和 `HIDRemoteMonitor.shouldRepeat` 规则。
- 仅当按键没有双击/长按绑定、动作允许重复且当前前台 App 允许重复时启动连发。
- 松键、断连、配置变化、权限失效或动作提交失败时取消计时器；日志按一次按住聚合记录 `operation_id`、间隔、停止原因和 `repeat_count`，不逐次刷屏。
- Siri 语音键按下后立即抑制当前触摸接触；语音活动及松键后的尾音自然排空期间，新触摸也不产生移动、滚动或点击。当前接触必须等手指离开后才恢复，避免恢复瞬间误点击。

## 自动化验证

- Siri Remote 专项测试验证返回键 50 ms、方向/音量 100 ms 的连发规则。
- 验证双击/长按绑定、不可重复动作和无线麦自身前台导航不会连发。
- 验证语音活动与尾音排空阶段均屏蔽触摸，接触结束后下一次触摸恢复。

## 真机验收边界

自动化不能证明真实 A2854 按住时系统持续产生用户可见删除，也不能证明所有目标 App 都接受重复合成键。必须重新执行原始场景：在真实文本框按住返回键 2 秒，确认连续删除；在 Siri 语音按住和松键排空期间移动、点击、转动触摸盘，确认没有指针/滚动/点击，且下一次新触摸可以恢复。
