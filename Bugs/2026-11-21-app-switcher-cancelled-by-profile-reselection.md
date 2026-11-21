# 切换 App 会话被重复选择设备档案取消

- 来源为 PR #1145 的 `49e2b13d`。同一档案重复选中也重载四项映射。实体按键的路由在切换器处理按键之前调用了档案选中入口。
- 2.0.9（412）中，Siri Remote 的 13 次会话均在第二次操作时以 `mapping_changed` 结束。普通 HID 有 31 次 `input_reset`，左、右键随后被普通映射消费。
- 同一档案选中只在需要时将临时选择升级为持久选择。合并后的档案继续通过独立重载入口应用内容。Siri Remote 会话内优先使用实体 OK 确认。非导航键按其单击绑定继续切换或关闭会话。
- 回归 `reselectingCurrentProfileDoesNotCancelButtonInteractions` 在修改前两次选中产生 8 次重置回调。候选包实测覆盖小米和 Siri Remote 的重复触发、左右、OK、返回和切换到另一设备后的清理。
