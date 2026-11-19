# Typeless 的 Fn 组合快捷键在 2.0.8 预览版后无法定义

- 时间：2026-11-20
- 状态：调查中；已补自动诊断日志；根因等待现场日志确认，尚未修改产品行为
- 影响范围：macOS；SayAll 2.0.8 预览版；Typeless 的 Fn 组合快捷键
- 功能点：物理 Fn 观察、软件 Fn 注入、快捷键录入、HID 级只读 Fn tap
- 原始记录：用户反馈；Typeless 设置截图未入库，本文只保留文字描述

## 现象

用户升级到 SayAll 2.0.8 预览版后，Typeless 中已有的两个 Fn 组合快捷键失效：

- 翻译：`Fn + Left Shift`、`Fn + T`
- 随便问：`Fn + Space`

用户补充：只要涉及 `Fn + 任意键` 的快捷键都无法被定义。截图只展示 Typeless 的快捷键配置，不包含输入内容或其他用户数据。

当前没有取得该用户的 SayAll 日志、macOS 版本、Typeless 版本，也没有在本机复现。本记录因此不把任何单一原因写成已确认根因。

## 已有证据

### 公开代码

1. **常驻的 active tap 不吞 Fn。** 自定义映射开启时，`KeyboardEventSuppressor` 在全系统安装 session 级 active tap，并监听 `.flagsChanged`；但 `descriptor()` 对 `.flagsChanged` 返回 `nil`，回调返回 `false`，Fn 继续向下游派发。[KeyboardEventSuppressor.swift](../Sources/RemoteMic/KeyboardEventSuppressor.swift)
2. **Mac 麦克风的 Fn 观察是只读的。** `MacMicrophoneVoiceKeyMonitor` 优先在 HID 头部安装 `.listenOnly` tap，回调返回原事件；只有用户开启“用所选麦克风说话”时才启动。[MacMicrophoneVoiceKeyMonitor.swift](../Sources/RemoteMic/MacMicrophoneVoiceKeyMonitor.swift)
3. **快捷键录入只在录入界面打开时吞键。** `ShortcutCaptureMonitor` 会吞掉 `.flagsChanged` 和 `.keyDown`，但它只在用户点击“录入快捷键”后短暂启用；不是常驻监听。[ShortcutCaptureMonitor.swift](../Sources/RemoteMic/ShortcutCaptureMonitor.swift)
4. **软件 Fn 注入有成对释放。** 遥控器语音、Chromecast 点按、手机语音等路径通过 `KeyboardInjector.setVoiceKeyPressed` 发送 Fn 按下/松开；点按路径延迟 120 ms 后释放。[KeyboardInjector.swift](../Sources/RemoteMic/KeyboardInjector.swift) [VoiceFnTapSessionController.swift](../Sources/RemoteMic/VoiceFnTapSessionController.swift)
5. **启动时没有清理上一次未配对的软件 Fn。** 如果进程在 Fn 按下与松开之间被强杀、崩溃或被安装器替换，系统可能一直认为 Fn 被按住；当前代码没有启动对账。按 `VoiceKeyMode.function.usesHardwareMapping`，Fn 语音模式在正常遥控器路径上依赖硬件映射，软件 Fn 只在 `forceSoftware` 路径出现，因此需要区分“硬件 Fn 残留”和“软件 Fn 残留”。[VoiceKeyMode.swift](../Sources/RemoteMic/VoiceKeyMode.swift) [BridgeAppModel.swift](../Sources/RemoteMic/BridgeAppModel.swift)
6. **2.0.8 发布提交本身不是 Fn 变更点。** `v2.0.8` 相对 `v2.0.6` 的差异只有版本元数据、版本历史和档案解码保护，没有 Fn、事件 tap 或快捷键代码。若用户从 1.9.x 升级，回归范围在 2.0.x 前面。

### 第三方边界

Typeless 自身会安装可修改或阻断事件的 active HID tap，并识别 keycode 63。此前的现场排查见 [Issue #139](https://github.com/HD838A/remote-mic-app/issues/139)。本仓库不读取 Typeless 的私有文件、配置或内部状态；只能记录 SayAll 侧观察到的 Fn 事件和提交结果。

## 根因假设

### H1：软件 Fn 未配对释放，系统一直认为 Fn 被按住（中等置信度）

正常路径有 120 ms 延迟释放和 `shutdown` 释放；但强杀、崩溃、安装器替换或 120 ms 窗口内退出可以只留下 Fn 按下。系统随后不再产生新的 Fn 按下边沿，Typeless 的快捷键录入和触发都收不到完整组合。

### H2：HID 级只读 Fn tap 与 Typeless 的 active HID tap 冲突（中低置信度）

按 API 语义 `.listenOnly` 不消费事件，但这是 2.0.x 唯一新增的全局 Fn 监听。如果 macOS 27 在多个 HID tap 并存时改变投递顺序，可能出现“SayAll 能观察、Typeless 收不到”或反向现象。需要日志中的 HID/session 观察对照。

### H3：非 SayAll 因素（中等置信度）

包括系统“按下 Fn/地球键时”不是“不执行任何操作”、Secure Keyboard Entry、Typeless 自身 Fn 状态卡住，或其他输入工具占用 Fn。这类原因与 SayAll 升级可能只是时间上重合。

### H4：SayAll 的快捷键录入界面仍在后台打开（低置信度）

该状态会吞掉所有按键，不会只吞 Fn。日志中的 `SHORTCUT CAPTURE phase=started` / `phase=stopped` 可以直接排除。

## 已补自动诊断

本轮只增加日志，不改变 Fn 投递、语音会话或快捷键行为。所有字段均为稳定枚举、布尔值或计数，不记录按键内容、字符、前台 App、窗口标题、设备身份或第三方私有状态。验收字段和判定顺序见 [Testing/RuntimeLogging.md 用例 11](../Testing/RuntimeLogging.md#用例-11typeless-fn-组合诊断)。

### 1. 启动与退出快照

```text
VOICE KEY fn_snapshot source=launch result=observed fn_flag=<bool> key63_down=<bool> secure_input=<bool> system_fn_usage=do_nothing|assigned|unknown voice_key_mode=<mode> voice_fn_tap=<bool> voice_tool=<tool>
VOICE KEY fn_snapshot source=terminate_begin ...
VOICE KEY fn_snapshot source=terminate_end ...
```

- `fn_flag`：`CGEventSource.flagsState(.hidSystemState)` 是否带 `.maskSecondaryFn`。
- `key63_down`：`CGEventSource.keyState(.hidSystemState, key: 63)`。
- 未授予辅助功能时记录 `result=skipped reason=accessibility_denied`，不会用推测值代替。
- `source=terminate_end` 在 `model.stop()` 之后记录，用于确认正常退出是否释放了 Fn。

### 2. Fn 边沿观察

```text
VOICE KEY fn_observe source=session_tap tap=session phase=observed synthetic=<bool> pressed=<bool> event_timestamp_ns=<n>
VOICE KEY fn_observe source=hid_tap tap=hid_head|session_head phase=observed synthetic=<bool> pressed=<bool> event_timestamp_ns=<n>
```

- `session_tap` 来自常驻的 `KeyboardEventSuppressor`；`hid_tap` 只在 Mac 麦克风监听开启时存在。
- 物理事件在两个 tap 中使用相同的 `event_timestamp_ns`，可以直接对照。合成事件可能为 0，需要结合 `synthetic=true` 和 `fn_submit` 判断。
- `synthetic=true` 表示这是 SayAll 自己发出的 Fn，不是物理 Fn。

### 3. 带 Fn 的按键观察

```text
VOICE KEY fn_combo_observe source=session_tap|hid_tap tap=<tap> phase=observed synthetic=<bool> primary_kind=unclassified|home|end|help|forward_delete|page_navigation|command_shortcut|arrow_* event_timestamp_ns=<n>
```

- 当 Fn 已经被按住、tap 没有看到 Fn 按下边沿时，这一行仍然会记录“某个按键带着 Fn 标志到达”。
- 不记录按键码或字符；普通字母组合统一为 `unclassified`。
- 方向键、Home、End、PageUp/PageDown、Help、Forward Delete 的原始 HID 快照会带伪 Fn 位，已从该观察中排除，普通方向键不会生成组合行。

### 4. 软件 Fn 提交

```text
VOICE KEY fn_submit mode=fn edge=down|up result=submitted|failed|rejected reason=none|accessibility_denied source=software synthetic=true event_flags=<mask> target_response=unknown
```

- `result=submitted` 只表示 `CGEventPost` 已调用，不表示 Typeless 已收到或已执行；因此保留 `target_response=unknown`。

### 5. 快捷键录入状态

```text
SHORTCUT CAPTURE phase=started result=listening source=session_tap
SHORTCUT CAPTURE phase=resolved result=captured main_thread=<bool> has_function=<bool> modifier_count=<n>
SHORTCUT CAPTURE phase=stopped result=inactive source=session_tap
```

- `has_function=true` 只表示 SayAll 的录入器看到了 Fn 标志；不代表 Typeless 的录入器看到了。
- 不记录快捷键名称、键码或字符。

### 日志量

新增行只由 Fn 边沿、带 Fn 的按键和快捷键录入触发。普通输入不产生日志；每个 tap 在一次 `Fn + 键` 中最多产生两条 `fn_observe`（按下、松开）和一条 `fn_combo_observe`，开启 Mac 麦克风时 HID/session 各一份。不新增周期行，因此不加入高频聚合白名单。

## 下次如何用日志定位

按以下顺序读取同一时间段：

1. **`fn_snapshot source=launch` 的 `key63_down=true`，且前一会话有 `fn_submit edge=down` 没有 `edge=up`，或有 `fn_observe pressed=true` 没有对应的 `pressed=false`** → Fn 残留（软件注入或遥控器硬件映射）。优先检查强制退出、崩溃、安装器替换或 120 ms 窗口内退出。修复方向是启动/退出对账，不是继续调 Typeless。
2. **`fn_snapshot key63_down=false`，但 `fn_combo_observe` 有记录、之前没有对应的 `fn_observe down`** → 系统或某个 active tap 把 Fn 按下边沿消费了。继续看 HID/session 两层。
3. **`fn_observe source=hid_tap` 存在，`source=session_tap` 缺失，时间戳相同** → 事件在 HID 与 session 之间被消费。Typeless 的 HID active tap 或其他输入工具进入候选；SayAll 自己的 session tap 不是原因。
4. **HID 和 session 两层 `fn_observe` 都存在，`SHORTCUT CAPTURE has_function=true`** → SayAll 已看到 Fn，失败点在 Typeless 或其上游。保留 `target_response=unknown` 边界，不能据此宣称 Typeless 内部失败。
5. **`fn_snapshot` 的 `system_fn_usage=assigned` 或 `secure_input=true`** → 外部配置或安全输入边界；不归因于 SayAll 代码。
6. **`SHORTCUT CAPTURE phase=started` 没有对应的 `phase=stopped`** → SayAll 的录入器仍在后台；这属于已知的“录入状态吞键”边界，先停止录入再复测。

用户不需要做 A/B 测试。按正常方式使用 SayAll 和 Typeless，故障后导出诊断日志即可。如果用户重启过 SayAll，`source=launch` 快照会直接给出当时的 Fn 状态。

## 验证

- 构建：`SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain` → `Build complete!`，无新增 warning。
- 定向测试：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'FnKeyDiagnosticsTests|KeyboardEventSuppressorTests|ShortcutCaptureMonitorTests|VoiceKeyModeTests'` → 90 项、4 个套件通过。
- 完整测试：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain` → 1543 项、113 个套件通过。
- 自动化覆盖：快照字段、权限跳过、Fn 边沿匹配、合成标记、带 Fn 的按键分类、快捷键录入的 `has_function`、软件 Fn 提交/拒绝日志，以及普通按键不产生 Fn 诊断。
- 未执行：真实 Typeless、真实物理 Fn、真实遥控器、macOS 27 的 HID/session 投递对照。上述自动化只证明日志字段和分支，不证明现场根因。

## 边界

- 未取得用户日志、macOS 版本和 Typeless 版本；没有在本机复现。
- 未读取 Typeless 的私有文件、数据库、配置或未公开协议。
- 不把 `fn_observe` 缺失直接写成“Typeless 消费了 Fn”；只写“事件未到达该层”。
- 不把 `fn_submit result=submitted` 写成“Typeless 已触发”。
- 截图属于用户界面证据，按仓库规则不入库；本记录只保留文本描述。

## 后续

1. 等待现场导出的诊断日志，按上面的决策树确认 H1/H2/H3。
2. 若确认 H1，单独实现“启动/退出软件 Fn 对账”：只释放 SayAll 自己留下的按下，不清理用户真实按住的 Fn。
3. 若确认 H2，评估用 `IOHIDManager` 直接观察内置键盘的 Fn 原始用法，替代 HID 级 `CGEventTap`，再做独立评审。
4. 若确认 H3，更新用户可见的排查说明；不在代码中绕过系统 Fn 设置或 Secure Keyboard Entry。
