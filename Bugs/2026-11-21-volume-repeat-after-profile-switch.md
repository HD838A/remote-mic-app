# 按下音量键触发档案切换后松键不停止重复

- 时间：2026-11-21
- 状态：候选修复；自动化通过，真实遥控器与系统音量验收待完成
- 影响范围：macOS；2.0.8 build 413 及同类构建；使用“按住：重复单击”的音量键，且存在多个可被按键解析到的设备档案
- 功能点：`BridgeAppModel.onButtonPressed`、`HIDRemoteMonitor.cancelMappingInteractions`、`resetInputState`、`RemoteButtonInteraction`

## 现场证据

用户提供 2.0.8 build 413 的运行日志，进程 `pid=64188`。一次音量加按下后出现以下顺序：

```text
18:04:53.928Z HID REPORT accepted ... buttons=volume_up path=manager
18:04:53.928Z HID EDGE pressed=volume_up released=none
18:04:53.928Z BUTTON HOLD ... reason=mapping_cancelled count=9
18:04:53.928Z HID FILTER arm events=sys0 edge=up
18:04:53.935Z HID GESTURE button=volume_up path=raw mode=repeatSingle
18:04:53.935Z HID BUTTON button=volume_up trigger=singleClick action=volumeUp
18:04:54.083Z HID REPORT accepted ... usage_count=0 buttons=none path=manager
18:04:54.286Z HID BUTTON button=volume_up ... action=volumeUp
18:04:54.386Z HID BUTTON button=volume_up ... action=volumeUp
18:04:54.487Z HID BUTTON button=volume_up ... action=volumeUp
```

关键异常有三处：

1. 按下的同一毫秒内出现 `BUTTON HOLD ... reason=mapping_cancelled count=9` 和四条 `BUTTON CONFIGURATION ... result=interactions_cancelled reason=mapping_changed`。
2. `18:04:54.083Z` 的零报告到达后没有 `HID EDGE ... released=volume_up`；松键边沿被丢掉。
3. 从 `18:04:54.286Z` 起，日志每隔约 100 ms 继续写 `HID BUTTON ... action=volumeUp`，直到下一次音量减按下才换键。

音量减在 `18:04:55.053Z` 复现同一顺序：`mapping_cancelled count=9`、`HID FILTER ... edge=up`、零报告无释放边沿，随后每 100 ms 重复。

## 根因

按下普通按键时，`BridgeAppModel.onButtonPressed` 调用 `selectRemoteProfile(resolvedProfileID)`。如果解析出的档案与当前选中档案不同，选择变化触发 `settings.onInteractionModeChanged`，再进入 `cancelButtonMappingInteractions`，最终调用 `HIDRemoteMonitor.cancelMappingInteractions`。

`cancelMappingInteractions` 调用了完整的 `resetInputState`，其中：

- `activeUsages.removeAll()` 清空物理按下集合；
- `physicalPressStartedAt` / `lastPhysicalReleaseAt` 被清空；
- 对仍在按下的 usage 预先 arm 了原生抬起。

下一次零报告到达时，`released = activeUsages - usages` 已经为空，松键无法被识别。`repeatSingle` 的计时器只在释放交互时取消，因此计时器继续每 100 ms 执行一次单击动作，表现为“按一下音量，音量一直加”。

## 修复

- `cancelMappingInteractions` 保留物理边沿状态：`activeUsages`、`nativePassthroughUsages`、按下/释放时间戳和当前按键显示；仍取消交互、重复计时器、App 切换器会话和手势识别。
- 新增诊断日志，记录映射取消时保留的物理边沿数量。
- 不改变现有“按键解析到其他档案时自动选中该档案”的产品行为；本修复只保证选中变化引发的映射重载不会伪造按键释放。

## 验证

自动化：

- `mappingResetWhileVolumeKeyIsHeldDoesNotLeaveRepeatRunning`：按住音量键期间调用 `cancelMappingInteractions()`，500 ms 前确有重复；零报告后继续推进 1 秒，动作数不再增加。修复前该测试得到 3 次动作后继续增长到 13 次，修复后保持 3 次。
- 公开宿主构建与目标测试通过，命令记录在交付说明中。

待现场验证：

- 使用真实 RC001 / RC003，在“按住：重复单击”下按一次音量加/减，确认松键立即停止。
- 在多个设备档案存在、按下会解析到非选中档案时，确认卡片不跳动、动作只执行一次、按住才重复。
- 连续快速按同一音量键、按住跨 350 ms、按住期间切换档案、断连和重连。
- 确认系统音量实际只按预期变化一次，且松键后无尾随动作。

## 边界

- 自动化验证的是 HID 报告、交互状态机和调度器，不替代真实遥控器固件、系统音量 HUD 和第三方 App 验收。
- 本修复不改变 AltTab 等未配置动作的原生透传，也不改变正常按住重复的节奏。
- 若真实环境仍出现松键边沿丢失，需要单独检查 CoreBluetooth/HID 报告投递与指纹过滤，不在本修复范围。
