# Upgrade Leaves Custom Button Mapping Inactive

- 时间：2026-08-10
- 状态：已修复，签名候选升级验证通过；待用户实体按键确认
- 影响范围：macOS 1.8.2；从旧预览版通过 Sparkle 升级且升级前已开启自定义按键
- 功能点：更新后 HID 监听恢复
- 简单描述：升级完成后开关仍显示开启，但实体遥控器动作不生效；手动关闭再开启后恢复。
- 原始记录：用户反馈、`~/Library/Logs/RemoteMic/runtime.log`、精确 `1.8.1 → 1.8.2` Sparkle 原位升级复现

## Observations

- 用户现场边界明确：持久化开关没有丢失，重新切换同一开关即可恢复，因此问题位于运行时 HID 监听恢复，不是映射配置解码或 UI 状态保存。
- 本机真实设置中 `customMappingEnabled = true`，两只遥控器 Profile 均没有已保存的 HID fingerprint；升级前后的设置值保持不变。
- 使用 GitHub Release 中逐字节校验通过的 `Remote-Mic-1.8.1.zip` 启动后，日志记录 `HID START`，并立即记录 `HID CONNECTED mode=monitored`。
- 使用项目固定 Sparkle 2.9.4 的官方 `sparkle-cli`，以 `v1.8.2/appcast.xml` 对上述正在运行的 1.8.1 App 执行真实原位更新。旧进程在 `03:58:28Z` 完成 `APP STOP`，新 1.8.2 进程在 `03:58:29Z` 启动。
- 1.8.2 升级重启后，权限仍为 `input=true accessibility=true`，电源键保护与事件过滤器均成功，且先后两次记录 `HID START mode=adaptive`；但观察窗口内没有 `HID CONNECTED` 或 `HID DEVICE OPEN FAILED`。
- 正常退出并冷启动同一份已升级 1.8.2 App 后，仍可观察到开关为开启、权限通过和 `HID START`，但未按实体键前没有设备激活日志。这与 1.8.2 将 discovery 设备激活推迟到首份报告的设计一致，不能单独证明冷启动按键失败。
- `v1.8.1..v1.8.2` 的 HID 关键差异是：未绑定 discovery monitor 在 `deviceDidMatch` 阶段不再打开任何枚举设备，而是等待首份 manager input report 后才调用 `activateDevice`。
- 现有回归测试只验证 `resolvedFingerprintForReport` 在“报告已经到达”后的路由结果，没有驱动真实 IOHIDManager 生命周期，也没有覆盖 Sparkle 替换进程后的运行时恢复。

## Hypotheses

### H1: Sparkle 更新重启时权限查询暂态失败

- Supports：重新切换会稍后再次执行 `applyHIDSettings()`。
- Conflicts：真实升级日志两次均记录 `input=true accessibility=true`，并成功进入 `HID START`。
- Test：检查升级重启窗口内权限日志及 start gate；若权限为 true 且 manager 已打开，则拒绝该假设。
- Result：rejected。

### H2: 1.8.2 discovery 推迟设备打开后，启动时没有形成可接收首份报告的稳定设备读取状态

- Supports：1.8.1 会在枚举阶段立即产生 `HID CONNECTED`；1.8.2 改为完全跳过 discovery 设备打开；现有测试只假设首份报告必然到达。
- Conflicts：IOHIDManager 理论上可以提供 manager 级报告回调；双遥控器功能曾由用户完成真机验证，说明该路径并非在所有运行状态下都必然失败。
- Test：执行真实升级并观察首份实体按键是否产生 `HID CONNECTED` / `HID BUTTON`；或用具备系统 virtual HID entitlement 的系统级回放驱动真实 manager callback。
- Result：自动化环境无法创建授权虚拟 HID；本机也无法代替用户物理按键，暂不能单独确认为普遍根因。

### H3: Sparkle 原位替换后的首次进程启动缺少一次延迟 HID 恢复（ROOT HYPOTHESIS）

- Supports：问题只在升级成功后的首次运行出现；旧进程 `APP STOP` 到新进程 HID 启动仅约一秒；用户稍后关闭再开启会完整停止并重建 monitors 后恢复；配置、权限、过滤器和电源键保护均正常。
- Conflicts：discovery monitor 在未收到首份报告前不会记录设备打开失败，因此现有日志无法直接显示底层占用错误。
- Test：在 completed-update 启动路径中只对已开启映射执行一次延迟的 monitor 重建，保持持久化开关不变；验证无需手动切换即可出现恢复日志，再用最终签名候选执行精确 Sparkle 升级。
- Result：confirmed at application lifecycle level。模拟 completed-update 启动时，持久化开关保持开启，日志自动产生 `HID UPDATE RECOVERY scheduled`，两秒后产生新的 `HID START` 和 `HID UPDATE RECOVERY applied`；普通启动和开关关闭状态不会进入该路径。底层 IOHID 在旧进程退出后的具体释放时刻没有公开可观测接口，因此不把未记录的内核占用细节写成已证明事实。

### H4: 升级时映射配置或开关持久化丢失

- Supports：UI 与运行时状态不一致通常可能来自迁移。
- Conflicts：`customMappingEnabled` 在更新前后均为 true；手动重新打开后原动作仍可工作，说明动作配置仍存在。
- Test：对比升级前后 UserDefaults 和配置解码。
- Result：rejected。

## Experiments

- E1：精确 Release 升级复现。使用 v1.8.1 官方 ZIP、项目固定 Sparkle CLI 和 v1.8.2 候选 appcast 完成真实替换与自动 relaunch；确认开关与权限正常，但升级后运行时只进入 `HID START`，未形成可证明动作可用的连接状态。
- E2：普通冷启动对照。退出并重新启动同一份 v1.8.2，仍在未按键时停留于 discovery waiting；说明 `HID CONNECTED` 缺失同时受 1.8.2 首报告绑定设计影响，不能仅靠该日志把问题归因于权限。
- E3：系统级 virtual HID 探针。按真实遥控器 VID/PID 和 Report Descriptor 创建诊断程序，但 macOS 26 要求受 Apple 授权的 `com.apple.developer.hid.virtual.device` entitlement；临时签名进程被系统终止，未产生有效报告。该失败只界定自动化能力，不能当作产品路径验证。

## Root Cause

App 只在新进程启动时立即调用一次 `applyHIDSettings()`，并把“IOHIDManager 已打开”当作已恢复完成。Sparkle 原位替换后的首次 relaunch 没有针对 HID 进程交接的延迟重建或重试；如果这一次启动没有形成可用报告链路，持久化开关仍为 true，后续也没有状态变化触发再次应用，因此 UI 一直显示开启但运行时保持失效。用户手动关闭再开启会调用 `applyHIDSettings()` 并重建 monitors，所以能够恢复。

现有测试只覆盖设置持久化、权限 gate、报告解析和“报告已经到达”后的指纹路由，没有覆盖 completed-update relaunch 后的 HID 恢复动作，因而没有阻止该回归。

## Fix

- completed-update 检测为 true 且持久化自定义按键开关为 true 时，启动后自动进入一次性 HID 恢复。
- 恢复过程不修改开关或任何按键配置：先停止本次过早建立的 monitors，等待两秒，再执行现有 `applyHIDSettings()` 完整重建权限、Power 保护、事件过滤器和 HID monitors。
- 普通启动、开关关闭状态均不触发；App 在延迟期间退出时取消任务，避免终止后重新启动监听。
- 增加 `HID UPDATE RECOVERY scheduled/applied` 日志，后续可以直接区分“配置开着”和“升级恢复已经真正执行”。

## Validation

- 修复前真实升级：GitHub Release `1.8.1 → 1.8.2` 的 Sparkle 原位升级稳定重现“开关/权限为 true、存在 `HID START`、但没有后续自动恢复”的状态。
- 修复后启动状态回放：将上一启动 build 设为 62，启动 build 63 的本地 App；日志确认无需切换开关即按顺序产生 `HID UPDATE RECOVERY scheduled delay_ms=2000`、新的 `HID START` 和 `HID UPDATE RECOVERY applied`，启动 build 自动保存为 63。
- 专项测试：`swift test --filter completedUpdateRecoversOnlyPersistentlyEnabledHIDMappingAfterStartup` 通过，覆盖只有“升级完成 + 开关开启”才恢复，并验证恢复发生在初次 `startIfNeeded()` 之后。
- 完整自动化：`swift test` 157 项通过；`./scripts/test.sh` 42 项通过；Production App 构建及 `./scripts/verify-app.sh` 通过；`git diff --check` 通过。
- 最终签名候选：Developer ID App、安装 PKG、卸载 PKG 和 DMG 均通过 Apple 公证、staple、Gatekeeper 与项目校验；Sparkle ZIP 的 EdDSA 签名和 appcast 签名验证通过。
- 精确签名升级：从 GitHub 官方 `Remote-Mic-1.8.2.zip` 解包 build 63，通过 Sparkle CLI 和最终 build 64 ZIP 执行真实原位更新。更新后的 App 保持 `customMappingEnabled = 1`，版本为 `1.8.3 (64)`，Developer ID 与公证验证通过；日志自动产生 `HID UPDATE RECOVERY scheduled delay_ms=2000`、新的 `HID START` 和 `HID UPDATE RECOVERY applied`，无需修改持久化开关。
- 最终包启动门禁：最终 ZIP 与 DMG 内 App 各启动两次，每次运行至少 15 秒后正常退出；四次均记录 `APP START version=1.8.3` 和 `HID START mode=adaptive`，没有新增 RemoteMic 崩溃报告。
- PKG 等价：安装 PKG 中的 App 与最终 ZIP App 的路径集合、文件字节、符号链接目标、文件类型和权限模式完全一致。
- 发布前 dry-run：重新验证六个待上传资产、版本、build、签名、公证、DMG checksum、appcast 和中英文 Release History；生成的 Release Note 包含本 Bug 修复。
- 边界：本机无法代替用户按实体遥控器；系统级 virtual HID 需要 Apple 专用 entitlement。Preview 发布后仍需用户确认升级后的第一枚真实按键无需切换开关即可执行，自动化与签名升级验证不冒充该项真机验收。
