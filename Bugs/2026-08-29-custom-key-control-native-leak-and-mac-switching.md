# 自定义按键 Control 组合、原始按键泄漏与跨 Mac 切换边界

## 状态

- Control + 四个方向键：候选修复完成；页面选择与实体键盘录入均已覆盖自动回归，等待 Mission Control 真机验收。
- 原始系统按键泄漏：候选修复完成，等待 RC003、目标输入框及第三方全局快捷键工具真机验收。
- 两台 Mac 切换：已补充可验证的 App 级 handoff 暂停，阻止当前 Mac 上的 SayAll 自动重连；macOS 系统配对/HID 迁移仍受公共 API 与真实硬件边界限制，不能宣称已自动切换。

## 影响范围

- Issue #257：Mission Control 所需 `Control + ↑ / ↓ / ← / →`。
- Issue #241：把音量键映射为复制/粘贴后，部分输入框仍收到系统音量事件；同一遥控器在 MacBook 与 Mac mini 之间切换时需要重新处理系统蓝牙连接。
- 自定义映射开启时的 RC003 普通按键，包括方向、确认、主页、菜单、TV、音量与电源。

## 复现

### Control + 方向键

1. 在自定义快捷键录入界面按住 Control，再按任一方向键。
2. macOS 为方向键事件隐式附带 `.function`，当前录入路径会原样保存。
3. 错误结果：快捷键被记录为 `Control + Fn + 方向键`，注入时同时带上 `maskControl` 和 `maskSecondaryFn`，与 Mission Control 需要的 `Control + 方向键` 不一致。

页面内标准键盘原本已经列出四个方向键并允许选中 Control，因此页面点选路径不是根因；问题集中在实体键盘录入事件的修饰键标准化。

### 原始按键泄漏

1. 启用自定义按键映射。
2. 把遥控器音量加/减映射为复制/粘贴，或把 TV/方向键映射为其他动作。
3. 在不同输入框或安装了全局快捷键工具的环境中按遥控器。
4. 错误结果：SayAll 动作执行的同时，macOS 或第三方工具仍收到遥控器键盘接口的原始音量、方向或符号键事件。

该问题在没有 RC003 的代理环境无法完成屏幕级复现；现有 Issue #241 描述与历史 RC003 真机证据一致：普通用户进程无法可靠独占设备，短窗口 Event Tap 也不能保证拦截所有系统级原始行为。

### 两台 Mac 切换

1. 同一只遥控器分别在 MacBook 和 Mac mini 配对或使用。
2. Mac A 上的 SayAll 保持运行；在 Mac B 尝试连接遥控器。
3. Issue #241 的现场结果：必须先在 Mac A 的系统蓝牙中“忽略此设备”，再到 Mac B 重新连接。
4. 修复前点击“立即重新连接”只会让 Mac A 的 SayAll 调用 `cancelPeripheralConnection`，随后约 0.1 秒再次连接；自动退避、系统唤醒恢复和 discovery 也会继续尝试连接，因此它既不是释放操作，也会增加当前 Mac 抢回 App 级 BLE 会话的可能。

用户期望是切换 Mac 时不再删除配对记录并重新配对，而不是只得到一段说明文字。

## 日志与证据

- Issue #241 报告最终用户行为：配置复制/粘贴后系统音量仍变化；切换 Mac 需要忽略并重新连接遥控器。
- Issue #241 没有附带切换时段的运行日志，因此目前不能确认“必须忽略”的唯一原因是 SayAll 自动重连、macOS HID 自动重连，还是 RC003 固件只保留一个主机；这些必须由两台 Mac 真机时间线区分。
- 当前运行日志只能证明 `HID BUTTON` 和 `SHORTCUT ACTION submitted`，不能证明系统或第三方工具没有同时收到原始事件。
- 修复前的 `origin/main` 只在设备级处理语音 F5 与电源键，其他 11 个普通按键仍依赖 Session Event Tap；这与“部分系统原操作仍会触发”的状态文案相符。
- 修复前 `XiaomiBluetoothBridge.reconnectNow()` 会先调用 `CBCentralManager.cancelPeripheralConnection`，再设置 0.1 秒重连；`recoverAfterSystemWake()` 同样调用重连。没有独立的“在当前 Mac 暂停并保持释放”状态。
- macOS SDK 中 `CBCentralManager.cancelPeripheralConnection` 只承诺取消本 App 的 active/pending CoreBluetooth connection；断开回调说明也限定为由 `connectPeripheral` 建立的连接。CoreBluetooth 没有公开的 unpair/forget 或迁移系统 HID 配对 API。
- `IOBluetoothDevice.closeConnection()` 是公开的 classic baseband API，但当前 App 只有 CoreBluetooth peripheral UUID，公共 API 没有可靠方式把它映射到选中的 `IOBluetoothDevice`；按名称匹配会在多遥控器环境误断设备，该 API 也不保证 macOS HID 不重新连接，因此不采用。

## 根因

1. RC003 通过一个键盘 HID 接口同时向 macOS 暴露普通按键。SayAll 从原始 HID report 执行自定义动作，但设备未被独占时，原生键盘事件仍会进入系统或高优先级全局监听器。
2. Event Tap 只按短时间窗口匹配原始事件，无法可靠覆盖系统音量、电源及所有第三方监听顺序，因此会形成“映射动作 + 原始动作”双重触发。
3. macOS 的方向键、导航键和 F 键事件可能隐式携带 `.function`；录入路径此前没有区分隐式 Fn 与用户在普通字母上明确按下的 Fn。
4. 跨 Mac 切换包含两层所有权：SayAll 自己建立的 ATVV CoreBluetooth 会话，以及 macOS 管理的系统配对/HID 会话。App 可以停止第一层并阻止自己重连，但没有公开 API 把第二层原子迁移到另一台 Mac。

## 修复

- 自定义映射启用时，在启动 HID monitor 前，为 RC003 全部 12 个普通按键写入设备级 `UserKeyMapping → 0`；SayAll 仍从原始 HID report 解析并执行配置动作。
- 写入后立即逐 service 读回校验；缺少任何受管映射时恢复写入前状态，对该设备位置失败关闭，不再把“写入调用返回成功”误当成已经阻止泄漏。
- 关闭映射或退出时恢复启动前的语音键与普通按键映射，同时保留无关映射。
- 录入 F 键、导航键和方向键时移除 macOS 隐式附带的 `.function`，普通字母上的显式 Fn 仍保留；为 `Control + ↑ / ↓ / ← / →` 增加页面选择、实体录入和注入回归测试。
- 为每个遥控器 Profile 持久化“暂停本机 SayAll 连接”状态。暂停时先保存状态再停止选中 bridge；启动连接、discovery、系统唤醒和 App 重启均排除该 peripheral，只有用户点击“恢复本机 SayAll 连接”才清除暂停并重新连接。
- handoff 按钮在暂停后打开系统蓝牙设置，供用户完成 macOS 管理的系统连接断开。日志明确记录 `app_reconnect=false` 与 `system_pairing_unchanged=true`，避免把 App 级暂停误报成系统配对迁移。
- 不调用按名称猜测设备的 `IOBluetoothDevice.closeConnection()`，不读取系统私有蓝牙数据库，也不尝试私有 unpair/forget API。

## 验证

- `swift test`：427 项测试通过。
- 定向 Swift 测试：5 个 suites、176 项测试通过，覆盖 12 键中和集合、写入读回失败回滚、按 Location 失败关闭、恢复原映射、Control + 四方向选择/录入/注入、handoff 暂停持久化、启动/discovery 排除、显式恢复和连接页接线。
- `./scripts/test.sh`：44 项项目自检通过，Debug build 通过，覆盖生产接线和映射策略。
- `git diff --check`：通过。
- 真实 RC003、系统音量 HUD、Mission Control、不同输入框、第三方全局快捷键工具，以及同一只遥控器在两台 Mac 之间切换仍需按测试手册验收。

## 下游影响

- 自定义映射关闭时仍恢复原生系统行为。
- 语音键继续使用独立 F5/Fn/Command 生命周期，不增加双击或长按入口。
- iPhone、Apple Watch 与网页版遥控器不经过 RC003 `UserKeyMapping`，行为不变。
- handoff 暂停只停止选中物理遥控器的 SayAll BLE/ATVV 自动连接，不关闭 Mac 蓝牙，也不修改其他蓝牙设备或其他遥控器 Profile。
- 仅使用公开 IOKit HID 属性与系统设置入口，不读取其他 App 内部数据。
