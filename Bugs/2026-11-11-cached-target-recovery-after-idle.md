# 长时间闲置后缓存直连持续被绕过

- 状态为候选，等待反馈机器的 RC003 睡眠唤醒与首次语音验收。
- 现场来源为用户提供的异机 2.0.0 Build 320 加密日志，共 8 段、87,819 条。原始日志及解密明文留在仓库外。
- 2026-11-11 01:57:36 UTC 收到系统唤醒并启动恢复，首次缓存直连约 8 秒超时。之后两条路径各累积 38 次失败，扫描持续重试且 `cached_identifier_bypassed=true`。
- 02:44:26 UTC 再次通过已保存身份直连，16 毫秒后连接，约 0.32 秒就绪。其后音频正常排空，丢弃、中断及 pending 样本均为零。

## 根因与证据边界

`BluetoothReconnectPolicy` 在缓存连接失败后把缓存直连关闭，自动扫描失败不恢复该开关。手动重连会 reset 策略，因此可再次直连。旧策略独立实验确认连续失败 38 次后缓存直连仍关闭。

本次可排除未收到唤醒和重试循环已停止。首次连接超时、睡眠期间系统蓝牙状态抖动的底层原因未知。日志缺少按钮点击事件与 source revision，恢复时序符合用户的手动重连描述，但不能单独证明点击动作或精确源码身份。

PR #921 处理缓存查询为空且扫描没有窗口的另一条路径。本次扫描窗口持续到期，候选查询已存在，新增修复只补缓存失败后的周期探测，保留原有扫描退避。

## 修复

缓存直连失败后，以单调时钟设置 60 秒冷却。冷却到期的下一轮发现可探测一次缓存目标，失败计数和 3～60 秒退避继续保留。探测暂时取不到设备时仍保持缓存绕过状态和 20 秒扫描窗口。正常 Ready、手动重连与停止沿用原有 reset。

探测日志使用 `BLE RECONNECT phase=probing reason=cached_target_cooldown_elapsed`，只包含失败计数和冷却时长。实际成功仍由 `BLE READY` 和音频终态确认。

## 验证

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain -j 4 --filter BluetoothLifecycleTests`。
- 定向覆盖冷却前后、一次性消耗、再次连接失败、38 次扫描失败、缓存暂时为空时扫描继续、reset 以及生产发现入口接线。
- 自动化不能替代真实 CoreBluetooth 和现场 Mac。实机步骤见 `Testing/BluetoothDisconnectAudioRelease.md` 的用例 10。
