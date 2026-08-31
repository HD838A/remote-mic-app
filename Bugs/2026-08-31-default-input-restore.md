+# Issue #283：恢复用户上次选择的物理输入设备

## 复现与日志

释放 SayAll 虚拟输入时，旧实现按内置设备优先策略选择第一个物理麦克风；Issue 现场使用 Elgato Wave XLR 时因此恢复到 BlackShark。日志与代码均确认该行为仍存在。

## 根因

`DefaultInputFallbackPolicy` 未保存用户最近一次非虚拟默认输入 UID，`BridgeAppModel` 只能调用内置设备优先的候选排序。

## 修复

监听默认输入变化，在非 App 管理切换期间记录最近用户选择的 UID，并在释放虚拟输入时优先恢复该 UID；设备缺失时继续使用原内置/首个候选回退。记录仅保存设备 UID，不进入配置导出。

## 验证

- `swift test --filter VirtualAudioConnectionLifecycleTests`
- 自动化覆盖记忆设备优先、设备缺失回退和受管切换不覆盖用户选择。
- 真实 Elgato/Wave Link 与热插拔验收仍需在目标 Mac 执行。
