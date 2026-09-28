# Siri Remote 多设备连接后触摸失效

## 复现证据

- 现场日志：`~/Library/Logs/RemoteMic/runtime.log`。
- 在两只 Apple Remote 已连接后，日志出现：

  ```text
  APPLE REMOTE TOUCH unavailable reason=multiple_devices
  ```

- 同一时间实体按键仍能产生 `APPLE REMOTE CONTROL` 事件，但没有后续 `APPLE REMOTE TOUCH phase=start` 或触摸 `operation_id`。

## 根因

触摸会话更新逻辑把 `interfaceCountByIdentity.count == 1` 当成必要条件。第二只遥控器连接或多接口枚举后，适配器主动停止触摸并清除 `touchDeviceIdentity`，因此触摸桥即使可用也没有事件路由目标。该判断没有利用最近实体按键确定私有触摸回调应归属的设备。

## 修复

- 记录最近一次规范化实体按下的设备实例 `preferredTouchDeviceIdentity`。
- 选择顺序为：已有仍在线的触摸目标 → 最近实体按键设备 → 唯一在线设备。
- 第二只遥控器接入时保留现有触摸会话；只有目标设备变化或目标断连时才取消并切换。
- 多设备且尚未收到实体按键时记录 `detail=waiting_for_recent_control`，不猜测来源。
- 中心区域轻微移动在 `0.22 s` / `0.03` 位移容差内继续保留 tap candidate，抬手仍只产生一次轻触点击；外圈触摸优先进入圆周/径向意图判断，不被轻触吸收。

## 验证

- 自动化：适配器身份选择、已有目标保持、无目标等待和轻微移动轻触回归测试。
- 私有包命令：`swift test --disable-keychain --package-path packages/audio-input-kit/siri-remote`。
- 公开宿主及带私有依赖宿主命令见交付记录。
- 真机边界：需要两只 Apple Remote 交替“先按实体键，再触摸”，确认触摸目标切换、已有接触不中断、目标断连后的取消与恢复。

## 日志边界

日志只记录稳定模型、阶段、结果、序列和去重原因，不记录蓝牙地址、序列号、触摸坐标、窗口标题或用户内容。
