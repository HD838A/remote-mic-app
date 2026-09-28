# Siri Remote 多设备触摸

## 复现证据

- 现场日志：`~/Library/Logs/RemoteMic/runtime.log`。
- 两只 Apple Remote 同时连接时，旧版本反复记录 `APPLE REMOTE TOUCH unavailable reason=multiple_devices`；实体键事件仍能正常产生。

## 根因

1. 触摸桥只保存 `MultitouchSupport` 返回的第一只外部触摸设备，且宿主在多设备时把触摸目标限制为单一身份。第二只遥控器没有独立回调路由；即使改为按源 ID 路由，原会话在第二只设备稍后连接时也不会重新注册新增触摸源。

## 修复

- 触摸桥注册所有符合条件的外部触摸源，并在回调中携带源 `LocationID`。
- `MultitouchSupport` 子服务与 Usage Page 13 HID 父接口的 Registry Entry ID 不同，但二者共享 `LocationID`；适配器以该位置源标识路由到对应遥控器身份，并为每个身份独立维护 contact 生命周期和取消事件。
- 设备连接或断开改变触摸拓扑时，先取消活动 contact、刷新 `MultitouchSupport` 会话，再重新注册当前全部源；普通按键事件不会触发无谓重启。

## 验证边界

- 自动化覆盖 `LocationID` 源回调契约、所有触摸源注册与设备拓扑变化时的会话刷新；当前机器的父 HID 接口和 `AppleMultitouchDevice` 子服务已只读核对为相同 `LocationID`。
- 真实验收仍需两只 Siri Remote：分别直接触摸、交替触摸、同时接触、断开其中一只后继续触摸，并确认 `runtime.log` 中每次触摸都能归属到正确设备。
