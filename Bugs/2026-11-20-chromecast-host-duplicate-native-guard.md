# 宿主重复原生输入门禁导致 Chromecast 按键全部被拒绝

- 时间：2026-11-20
- 状态：候选修复
- 影响范围：Chromecast 普通按键；独占成功但原生输入 service 暂未枚举的首次连接
- 用户现象：长时间运行 SayAll 后 Chromecast 按键无响应，语音键正常

## 现场证据

Build 411 首次连接：

```text
HID NATIVE MAPPING phase=prepare result=pending reason=no_service family=chromecast
native_prepare result=failed before=seize
CHROMECAST HID phase=activation result=accepted reason=seized_isolation
CHROMECAST HID phase=connected mode=mapped seized=true
```

之后每次按键：

```text
CHROMECAST HID press ...
CHROMECAST ACTION rejected reason=native_input_not_verified
```

本次日志共 39 次按键、78 条拒绝，没有任何一次 `CHROMECAST ACTION result=dispatched`；同期 4 次 Chromecast 语音会话全部 `result=passed`。

首次按键发生在连接约 8 小时后，但拒绝原因在首次连接时已经形成，不是长时间运行后新增的退化。

## 根因

私有桥在 `handleReport` 内已经用 `nativeInputReady` 过滤报告：

- 独占成功 → `nativeInputReady = true`
- 观察模式且原生屏蔽失败 → `nativeInputReady = false`，不会发出按键事件
- 原生屏蔽成功 → `nativeInputReady = true`

宿主 `handleChromecastControlEvent` 又检查 `chromecastNativeKeyMapper.isPrepared`。首次 `prepare` 失败后该值一直为 `false`，于是所有已经通过私有桥门禁的按键被宿主再次拒绝。

这是重复门禁，且在“独占成功、service 未枚举”时语义错误：独占本身已经阻断系统按键路径。

## 修复

- 删除 `handleChromecastControlEvent` 中的 `chromecastNativeKeyMapper.isPrepared` 检查。
- 保留私有桥的 `nativeInputReady` 作为唯一按键安全门禁。
- 新增回归：宿主源码不得重新出现该检查或对应拒绝日志。

## 边界

- 不修改私有包、ATVV 语音、设备档案或连接逻辑。
- 观察模式下私有桥仍未准备成功时不会发出事件，宿主不会执行未隔离的按键。
- 真实 Chromecast 首次连接按键仍需在新 App 构建中复验。

## 验证

- 待执行：定向 Chromecast 集成测试、公开全量测试、公开构建和仓库治理检查。
