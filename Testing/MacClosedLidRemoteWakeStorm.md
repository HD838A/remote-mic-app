# Mac 合盖后遥控器 HID 频繁唤醒测试

## 适用范围

- 原始回归基线：`v1.9.16` Tag `420767d6100de20e27f4d97f1e15beb20c1aa71e`
- 当前集成基线：upstream `main` `b65ae40308da35d026217f1e824e07b59af84e79`（`1.9.18 (171)`，包含 PR #296）
- 修复分支：`codex/integrate-closed-lid-runtime-suspension-20260829`
- GitHub Issue：[#240](https://github.com/HD838A/remote-mic-app/issues/240)
- 平台：Apple Silicon macOS 14+；Intel macOS 13 需要单独执行兼容回归
- 遥控器：RC001 为原始复现设备；RC003 为共享 BLE / HID / Power 安全门回归设备

## 测试前准备

1. 使用项目正式测试包；记录版本、Build、Commit、签名 Team ID 和 macOS Build。
2. 只运行一个 SayAll 实例，确认活动监视器和日志中的 `instance_id` 一致。
3. 保存当前电源设置，接通电源；测试结束后恢复原设置。
4. 准备一个已绑定的 RC001。RC003 用例使用单独 profile，不能混淆设备日志。
5. 授予输入监控和辅助功能权限，分别准备“自定义映射关闭”和“自定义映射开启”状态。
6. 语音输出先选择“无”；后续音频回归再选择 MiRemoteV 2ch 或其他已验证虚拟设备。
7. 记录测试开始 UTC，并保存以下基线：
   - `pmset -g assertions`
   - `pmset -g log | tail -300`
   - `~/Library/Logs/RemoteMic/runtime.log` 当前行数
   - SayAll、`bluetoothd`、WindowServer 的 CPU、RSS 和 Energy Impact
8. 确认“电池设置 → 选项”中可能影响网络唤醒的设置并记录，不得在对照组之间改变。

## 用例一：App 停止的系统/固件对照

1. 完全退出 SayAll。
2. 保持 RC001 在 Mac 附近，不按任何按键。
3. 合盖至少 30 分钟。
4. 开盖后立即保存 `pmset -g log` 对应区间。

预期：记录 macOS/RC001 在没有 SayAll 客户端时的 DarkWake/FullWake 基线。

失败判定：本用例不是候选代码成败判定；如果仍稳定每 47～48 秒出现 `Bluetooth LE HID Activity → FullWake`，说明初始唤醒不依赖 SayAll，必须把系统/固件因素写入结论。

## 用例二：映射关闭时合盖一小时

1. 启动 SayAll，关闭自定义按键映射，语音输出保持“无”。
2. 确认 RC001 BLE Ready 后合盖至少 60 分钟。
3. 开盖，保存 App 日志和 `pmset -g log`。

预期 App 日志：

1. `SYSTEM REMOTE event=system_will_sleep action=suspend`
2. `SYSTEM REMOTE suspended ...`
3. DarkWake 如果产生，只允许 `system_did_wake → resume_scheduled`；在约 10 秒后再次休眠时出现 `resume_cancelled`，中间不得出现 `BLE SCANNING`、`BLE CONNECTING`、`BLE READY` 或 `HID START`。
   - 若睡眠前存在 `HID MAPPING RECOVERY scheduled`，还必须先出现 `HID MAPPING RECOVERY cancelled reason=system_sleep`；`sleeping` / `wake_pending` 期间不得再次安排或执行恢复。
4. 真实开盖后出现 `SYSTEM REMOTE resumed reason=user_visible_...` 或稳定窗口恢复。

预期系统结果：相较 v1.9.8 原始记录，不再由 SayAll 每约 48 秒放大出一整组 BLE/HID 重建。若 App 停止对照没有 FullWake，本用例也不得出现固定频率 FullWake。

失败判定：睡眠期间出现 BLE scan/connect、HID runtime 重建、恢复 timer 未被下一次 `systemWillSleep` 取消，或 FullWake 数量与原始 48 秒风暴等价。

## 用例三：映射开启时合盖一小时

1. 开启自定义映射，确认一个普通按键动作正常。
2. 合盖至少 60 分钟，RC001 保持在附近且无人触碰。
3. 开盖后保存同样日志。

预期：与用例二相同；休眠前关闭 IOHID managers/event suppressor，但保留 profile、映射和 Power 安全映射。睡眠期间不得重复 `VOICE FN MAPPING applied` 或成对 `HID START`。

失败判定：映射开启重新引入固定频率 FullWake，或开盖后配置丢失。

## 用例四：真实开盖后的首次操作

1. 从用例三保持合盖至少 2 分钟。
2. 开盖后立即按一次普通 OK/方向键，不进入设置、不手动重连。
3. 观察目标动作；随后再按三次不同普通按键。

预期：显示器 active 且合盖状态解除后立即恢复，不强制等待 15 秒；第一颗按键和后续按键均只执行一次。日志只出现一轮 `SYSTEM REMOTE resumed`、BLE 恢复和 HID runtime 准备。

失败判定：第一颗按键丢失、必须手动重连、等待超过 15 秒、执行两次，或真实唤醒后首个 BLE Ready 没有完成 `v1.9.16` 既有的一次 HID 恢复应用。一次真实唤醒允许“恢复时应用 + 首个 Ready 后校准”，但 DarkWake 保持暂停期间不得出现任何 HID 重建。

## 用例五：唤醒后的第一次语音用户旅程

1. 选择 MiRemoteV 2ch 或已验证虚拟音频设备，确认休眠前短语音正常。
2. 合盖至少 2 分钟后开盖。
3. 执行“普通 App/快捷键动作 → 目标输入框就绪 → 第一次 `STREAM_START → AUDIO → STREAM_STOP`”。
4. 再执行第二次短语音和一次 30 秒语音。

预期：第一次即成功，并按当前选择产生一组正确 Fn、Fn 点按、左 Command 或右 Command 事件和完整音频，不丢首字、不截尾、不要求重新选择设备；日志无旧 sleep generation 或 HID recovery generation 的迟到回调冲掉新会话。

失败判定：第二次才成功、首句无声、重复 Fn、音频不完整、旧 resume timer 在新会话中触发，或默认输入覆盖用户睡眠期间的新选择。

## 用例六：RC003 Power 安全与稳定基线

分别在自定义映射关闭、开启执行：

1. 普通方向、OK、返回、音量动作。
2. Power 自定义动作，确认不会触发 macOS 睡眠/锁屏原始 Power 路径。
3. 合盖至少 30 分钟后开盖，重复首个普通按键和首次普通语音。

预期：开启映射时继续保留设备级 `Keyboard Power → F20`；系统睡眠期间停止 monitor 不得恢复危险 Power 原映射。Fn、左 Command、右 Command 语音模式分别在第一次语音即成功；关闭映射时行为与上一稳定版一致。

失败判定：系统日志出现对应原始 Power 睡眠事件、普通动作失效、首按丢失或 RC003 `STREAM_START → AUDIO → STREAM_STOP` 回归。

## 用例七：边界状态

独立执行：

1. 系统将睡眠时 BLE 正在连接。
2. 系统将睡眠时 RC001/RC003 正在传输语音。
   - 预期：先记录 `ATVV STREAM interrupted reason=system_sleep`，释放当前语音键并结束实体遥控器会话，再 detach BLE；开盖后第一次语音创建全新会话，不继承睡眠前的设备 ID、按键 latch 或 trace。
3. `systemDidWake` 后 10 秒内再次 `systemWillSleep`。
4. 锁屏但不睡眠、只关闭显示器、切换用户会话。
5. 外接显示器且 MacBook 合盖。
6. 蓝牙在睡眠前关闭，开盖后再开启。
7. 手机/Web/Watch 已启用但实体遥控器没有活动语音。

预期：只有真正的 `systemWillSleep` 暂停实体遥控器 runtime；普通锁屏/显示器休眠不错误销毁 BLE。迟到回调和重复通知幂等，不跨 generation 恢复。移动端稳定功能不因实体遥控器暂停而产生占用残留。

失败判定：任一迟到 callback 绕过暂停门、DarkWake 恢复 runtime、移动语音状态残留，或真实用户唤醒无法恢复。

## 长时间回归

候选短时用例通过后，至少运行 24 小时：

- 期间包含一次 8 小时以上合盖；
- 白天执行至少 20 次普通按键、10 次短语音、一次 60 秒语音；
- 比较运行前后 SayAll RSS、线程数、文件描述符、日志大小、`bluetoothd` 和 WindowServer CPU/Energy；
- 确认没有固定频率 BLE/HID 生命周期、日志风暴或随时间恶化的系统响应。

## 日志收集

发生失败时提供：

- 精确 UTC 的启动、合盖、每次开盖、首次按键、首次语音和退出时间；
- 对应 `runtime.log` 区间；
- `pmset -g log` 对应区间和 `pmset -g assertions`；
- Activity Monitor CPU/Memory/Energy 截图；
- macOS Build、Mac 型号、供电状态、远程型号、自定义映射和音频设备状态；
- 如出现卡顿，额外采集 SayAll、`bluetoothd`、WindowServer 的 5 秒 sample。

重点检索：`SYSTEM REMOTE`、`SYSTEM AUDIO`、`BLE`、`HID`、`VOICE FN MAPPING`、`ATVV STREAM`。

## 自动化、代理与用户实测边界

- 自动化可证明状态机、重复事件、generation、DarkWake 取消、稳定窗口和生产接线。
- Debug/Release 构建、签名、公证只能证明各自边界，不能证明合盖电源行为。
- 代理当前读取了真实 v1.9.8 日志和 `pmset` 复现证据，但尚未使用候选代码完成真实合盖。
- 只有真实 RC001/RC003、真实合盖、CoreBluetooth/IOHID、`pmset` 和首次用户旅程能完成最终验收；这些未通过前，候选不得表述为已解决真机 wake storm。
