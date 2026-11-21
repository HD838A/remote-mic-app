# 小米普通按键误用另一台设备的档案

## 证据与根因

隔离测试登记 A、B 两台的 BLE 档案并选中 A。先前的 HID 登记直接把 B 的指纹写到 A，因为 A 缺少 HID 指纹，导致 B 按键执行 A 的动作。使用测试生成的 UUID 与指纹复现，暂无实机报告。

## 修复与验证

小米 HID 到达后按系统 UUID 指纹查找唯一的 BLE 档案。无唯一身份时走独立档案，只允许使用没有两种传输身份的临时空档案。新增回归覆盖不同设备、同一设备 BLE 先到以及首次 HID 未识别的安全行为。运行 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfilePersistenceTests|RemoteButtonsTests'`。真实 RC001/RC003 的两种到达顺序需实测。
