# 左右键按住不能连续移动

- 时间：2026-08-10
- 状态：候选修复完成，硬件模拟通过，等待真机验证
- 影响范围：macOS 1.8.x；遥控器左右方向键按住
- 功能点：HID 按住重复与前台动作策略
- 简单描述：左右键单击配置为方向键、双击和长按未配置时，用户在其他前台 APP 的输入框中观察到按住不能连续移动文本插入光标。
- 原始记录：当前用户反馈和本机持久化配置检查

## 观察

- 当前两只遥控器的持久化配置均为左键 `arrowLeft`、右键 `arrowRight`，`secondaryButtonBindings` 为空，确认不是双击或长按动作占用了按住行为。
- `ButtonAction.arrowLeft / arrowRight` 的 `allowsRepeat` 为 `true`，物理左右键的重复间隔为 100ms。
- `HIDRemoteMonitor.shouldRepeat` 有一个明确例外：无线麦自身位于前台时，方向键和删除键一律不允许重复。
- 该例外来自 2026-08-09 的错误提示音修复；当设置页没有可接受方向键的控件时，连续注入方向键会让 macOS 持续播放错误音。
- 用户确认失效时前台不是无线麦，且“移动鼠标”明确指输入框里的文本插入光标，不是屏幕鼠标指针；因此排除前台抑制和新鼠标功能两个方向。
- 2026-08-10 14:18:21Z 的现场日志只记录了一次 `HID BUTTON button=left trigger=singleClick action=arrowLeft`。现有重复 timer 直接调用 `actionPerformer`，不写 `HID BUTTON` 日志，所以该记录无法证明 timer 是否启动、提前取消或成功执行。
- 现有硬件报告模拟证明方向键在 Codex 等其他 APP 前台时允许重复，但它使用预设的持续按住报告，不能证明真实遥控器在本次场景中保持 usage 超过 350ms。
- 现场启动日志确认两只遥控器均为 `HID CONNECTED mode=monitored seize_error=-536870207`；现有硬件模拟却使用 `isSeized: true`，没有覆盖生产监听模式。
- 左右键的原始 HID usage 会被 macOS 识别为原生 `← / →`，并由系统负责按住连发。监听模式当前仍先拦截原生事件，再依赖无线麦后台主线程 timer 重造按键，因此对系统原生连发做了不必要且更脆弱的替换。

## 假设

### H1：监听模式错误拦截了与映射完全一致的系统原生方向键连发（当前首要假设）

- 支持：现场设备明确处于 monitored 模式；左右键原始事件和配置动作完全一致；当前代码会抑制原生 keyDown/keyUp 并改用 App timer；现有模拟只测 seized 模式。
- 冲突：当前无法用进程内模拟证明 WindowServer 一定生成原生自动连发，但标准键盘方向键 HID usage 的系统行为明确，且历史现场日志曾观察到左右键原始重复周期。
- 实验：把硬件模拟改为 monitored 模式，验证当前实现会吞掉原生左右键并额外执行 App 注入；修复后应让匹配的原生左右键透传，同时保留非匹配动作、辅助动作和无线麦前台的抑制路径。

### H2：真实 HID 在 350ms 前上报松开，重复 timer 被提前取消

- 支持：现场只有首次动作记录；timer 必须保持 `activeUsages` 含有对应 usage 到 350ms 才会产生首个重复。
- 冲突：历史真实日志显示左右键能够产生密集重复原始事件；匹配动作改走系统原生路径后不再依赖 App timer。
- 实验：若 monitored 原生路径仍失败，再增加 raw report 时间记录并比较 release 是否早于首个 tick。

### H3：按住期间 profile、权限或 monitor 状态变化，清空输入状态

- 支持：`stop()`、设备移除、权限失效和模拟设备切换都会执行 `resetInputState()` 并取消 timer。
- 冲突：现场日志附近没有 `HID RELEASED`、`HID DISCONNECTED` 或新的 `HID START`。
- 实验：在重复生命周期日志中记录取消来源；同时核对现场区间的 monitor 生命周期日志。

## 下一步

先让硬件模拟覆盖生产 `mode=monitored`：其他 APP 前台、左右物理键映射为对应方向动作且无辅助动作时，应透传 macOS 原生事件；无线麦前台、动作不匹配或存在双击/长按动作时仍走现有抑制和 App 动作路径。若该边界修复后通过完整回归，则发布 Preview，但明确记录尚未完成实体遥控器验收。

## 实验

- 新增 monitored 模式硬件模拟后，修复前左右键各产生 6 次 App 注入动作，同时 `KeyboardEventSuppressor` 继续吞掉对应原生方向键，确认既有测试只覆盖 seized 模式并遗漏了真实生产路径。
- 改为匹配动作原生透传后，相同模拟不再产生 App 注入，原生方向事件不再被 suppressor 拦截。
- 将左右键映射为音量动作时，模拟确认 App 连发仍执行 6 次；同时暴露出旧 timer 每次 tick 都重复增加 held count、但物理松开只减少一次，导致松开后原生方向键继续被拦截。
- 删除 timer tick 的重复 arm 后，非匹配动作保持连发，松开后 suppressor 状态恢复；无线麦前台仍只执行一次方向动作，不进入原生透传。

## 根因

真实遥控器处于 IOHID monitored fallback 时，左右物理键已经具有与目标映射完全一致的 macOS 原生方向事件，但无线麦仍将这些事件拦截并改用后台 timer 重造连发；同时 timer tick 错误地反复增加原生事件 held count，使一次物理松开无法完整释放抑制状态。现有硬件模拟默认使用 seized 模式，因而没有覆盖这两个监听模式问题。

## 修复

- 仅在 monitored 模式、其他 APP 前台、没有双击或长按动作，且物理左/右键正好映射为 `arrowLeft / arrowRight` 时透传 macOS 原生事件，让系统负责文本光标连续移动。
- 独占成功、动作不匹配、存在辅助动作或无线麦自身前台时继续使用现有 App 动作与抑制策略。
- App timer 连发不再重复 arm 原生按下状态，物理 release 可以完整解除事件抑制。
- 重置 HID 输入状态时同时清空原生透传 usage，避免断连或 monitor 重启残留。

## 验证

- focused monitored-mode 硬件模拟：3 个测试、5 个参数用例通过。
- seized 模式原有左右方向 App timer 连发仍保留，避免独占成功设备失去连续动作。
- 当前自动化边界到生产 raw HID parser、monitor 状态机、计时器、事件抑制和 action performer；进程内模拟不能证明 WindowServer 在实体遥控器上生成原生自动连发，因此 Preview 仍需用户完成真实输入框验收。
