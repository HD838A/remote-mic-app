# 小米 2 Pro 原生映射校验失败后整场不再接管按键

- 版本：2.0.10（Build 431），macOS 27，Apple Silicon
- 影响范围：小米 RC001/RC003 的普通按键与音量键；语音链路不受影响

## 现象和证据

遥控器在卡片与菜单里都是"已连接"，BLE 就绪、电量可读，语音键录音与转发全部正常，但整场会话里普通按键完全不响应，卡片显示「按键异常」。

解密后的当次会话日志（`~/Library/Logs/RemoteMic`）显示失败只发生一次：

```text
seq=26  VOICE FN MAPPING applied=true neutralized=false ... voice_readback=mismatched
seq=27  HID NATIVE MAPPING phase=prepare result=failed reason=mapping_not_verified
        attempted=1 restored=1 family=xiaomi
seq=56  HID START rejected power_suppressed=false
seq=58  HID START rejected power_suppressed=false
```

之后整场会话再没有任何 `HID NATIVE MAPPING phase=prepare` 尝试，也没有任何 `HID MAPPING RECOVERY` 记录，直到 App 重启。同一时刻系统里这台遥控器被枚举出 3 个服务：一个真实 HID 服务，另有两个 `LocationID=0`、产品名带虚拟前缀的重复服务；约二十分钟后再采样，两个重复服务已经消失。

历史对照：11-21 与 11-22 的多数会话是 `prepare result=verified services=1`，按键正常；本次是 `attempted=1 restored=1`——真实服务本来已经匹配，只有那一个瞬时多出来的重复服务需要写入，写入后回读不一致即整体回滚并放弃接管。

## 根因

`RemoteNativeKeyMapper.prepare()` 的语义是「写入 → 立即回读 → 不一致就整体回滚并返回失败」，`HIDRemoteMonitor.prepareNativeKeyMapping()` 随即拒绝接管设备。两条既有重试入口都以 `!hasMatchingServices` 为门槛（`HIDMappingRecoveryPolicy.retryDelay` / `deviceVerificationRetryDelay`），只覆盖"服务还枚举不出来"的 `no_service`；而本次失败的判据恰恰是"服务在、但校验不一致"，`hasMatchingServices == true`，因此 `retryDelay` 返回 `nil`，一次都不会重试。

重复服务是瞬时的（同一台机器上十几分钟后自行消失），所以真正的缺陷不是"存在重复服务"，而是**一次瞬时校验失败就让整场会话不再尝试**。

## 修复

- `HIDMappingRecoveryPolicy` 新增 `verificationFailedRetryDelay`：沿用同一组有限退避（0.5/1/2/4/8 秒），但**不以 `hasMatchingServices` 为门槛**，只要求已启动且未超出预算，负索引与越界都返回 `nil`。
- `BridgeAppModel.scheduleHIDMappingRecoveryIfNeeded` 增加 `verificationFailed` 分支，使用独立计数 `hidVerificationRecoveryAttempt`；该计数只由一次成功接管（`button_mapping.status.connected*`）清零，避免与 `completeHIDMappingRecoveryIfNeeded` 互相重置成无限重试。校验失败类重试不在工作项里自我续排：成功由状态回调收尾，再次失败由新的失败回调重新排程。
- 重试前仍检查 `customMappingEnabled` 与输入监控/辅助功能权限，权限缺失或映射关闭时不排程。
- 诊断：`RemoteNativeKeyMapper` 增加 `phase=enumerate`（服务数、无 location 的服务数，仅在数量不等于 1 时列出逐项）与逐次写入的 `phase=write`（registry/location/是否虚拟命名/写入与回读条数/缺失 source），失败汇总补 `failed_service`；只输出数值与"是否带虚拟前缀"这一位布尔，不写设备名称。

## 验证

| 范围 | 命令或证据 | 结果 |
| --- | --- | --- |
| 新增策略用例 | `--filter 'verificationFailureRetriesEvenWhenServicesExist'` | 通过 |
| HID 与语音键相关套件 | `--filter 'BluetoothLifecycleTests\|VoiceKeyModeTests'` | 72 项 / 2 套件通过 |
| 全量公开测试 | `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --disable-sandbox` | 见 PR 记录 |
| 治理检查 | `scripts/verify-repository-governance.sh` | passed |

## 未覆盖

- 未在本机复现"瞬时重复服务 + 校验失败"，重试路径只有策略级自动化覆盖；真机需要在下一次出现「按键异常」时确认 `HID MAPPING RECOVERY scheduled trigger=mapping_not_verified` 出现并在一次重试内恢复。
- 未改变"校验失败即回滚"的既有语义，也没有扩大或缩小目标服务集合。
