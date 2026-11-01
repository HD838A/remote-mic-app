# 自定义快捷键修饰键生命周期测试

## 2026-10-29 主页键伪 Fn（Fn-only 快照）回归

本次是 [2026-10-20 执行阶段伪 Fn](../Bugs/2026-10-20-shortcut-inherits-navigation-function.html) 的同类残留：既有过滤只处理“Fn + 数字键盘位”的方向键快照，主页键（Home，键码 115）在 Intel 机器上只带 Fn，因此 Fn 被并入已配置的快捷键。

1. Intel 机器上把遥控器主页键和下键都配置为 `Command + Shift + H`，在 Chrome 前台分别触发。
2. 下键应打开主页；主页键在修复后必须打开同一个主页，行为与下键一致。
3. 从 App 日志菜单保留该时间段日志，按 `SHORTCUT SEQUENCE operation_id` 查请求行。
   期望 `hardware_function_state=unobserved`、`hardware_function_filtered=true`、
   `physical_flags=0`，且 `key_down` 事件的行为 `0x12000a`，不含 `.maskSecondaryFn`。
   修复前同一请求记为 `hardware_function_filtered=false`、`physical_flags=8388608`、
   `event_flags=9568266`，即 `Fn + Command + Shift + H`。
4. 用 PageUp / PageDown（键码 116 / 121）、End、Forward Delete 重复第 1 步，均不得带 Fn。
5. Apple 芯片机器上重复第 1、3 步，结果必须与 Intel 一致，且不得出现新的按键残留。
6. 显式配置 Fn 组合（如 `Fn + Command + L`）：Fn 仍须随按下与松开发送，不因本次过滤消失。
7. 实体键盘先按住 Fn 再触发遥控器快捷键：真实 Fn 继续保留，松开后再触发不得带 Fn。
8. 语音键为 Fn 时按住不放，同时触发一个不含 Fn 的快捷键；该快捷键不得带 Fn。
9. 快速连按主页键，把 `HID PRESS rejected reason=awaiting_stable_release` 与快捷键投递分开统计，
   该项是 600 ms 稳定释放保护，不属于本次 Fn 修复范围。

失败判定：`phase=requested` 里 `physical_flags` 出现 `8388608`、`key_down` 事件带 `event_function=true`、
显式 Fn 组合丢失 Fn、真实按住的 Fn 被丢弃、或修饰键在 `phase=completed` 后仍残留。

自动化：`swift test --disable-keychain --filter 'ShortcutLifecycleTests'` 通过 30 项；
`swift test --disable-keychain` 通过 1073 项、79 个套件。
覆盖 Fn-only 快照过滤、显式 Fn 保留、真实按住 Fn 保留、诊断字段和 1248 种配置矩阵。

真机结果（2026-10-29，Intel 机器，本地候选包 build 271，用户自测通过）：
`Command + Shift + H` 在主页键和下键上都打开了 Chrome 主页；该会话共 34 次快捷键请求全部
`phase=completed`，68 条 `SHORTCUT OBSERVATION` 全部 `result=passed_through` 且 `flags_match=true`，
204 个已投递事件全部 `event_function=false`、`physical_flags=0`。主页键有 24 次在
`hardware_flags=8388608`（仅 Fn）的快照下触发，全部记为 `hardware_function_filtered=true`；
其余 6 次快照为 `0`、1 次为 `0xA00000`，下键 2 次为 `8388608`，均未把 Fn 带进事件。

仍未验证：Apple 芯片回归、实体键盘按住 Fn 的组合、语音键 Fn 注入期间触发快捷键，以及
PageUp / PageDown、End、Forward Delete 四个同族键位。

## 2026-10-29 失效 Fn 状态、Help 键位与 Fn 层诊断分类

适用分支：`codex/shortcut-stale-fn-and-help-flag-20261029`。
本次改三处注入侧行为，遥控器按键、原生动作与普通按键注入不变。

1. 事件过滤器被系统禁用（安全输入、回调超时）后复位 Fn 状态，不再保留失效的
   `pressed`。此前若松开的 Fn 边沿正好落在禁用窗口里，之后每个快捷键都会带上 Fn，
   直到下一次真实按下 Fn。
2. `Help` / `Insert` 用法写进硬件快照的 Help 位不再并入合成事件；大小写锁定位仍保留，
   合成字母不会退化成小写。
3. 裸 Home / End / Help / Forward Delete 补齐 `primary_kind`（`home`、`end`、`help`、
   `forward_delete`，翻页仍是 `page_navigation`），带 Command 的快捷键仍记
   `command_shortcut`。

### 手动验收

1. 记录来源提交、Build 和 macOS 版本，确认输入监控与辅助功能已授权，连接遥控器并退出按键捕获模式。
2. **状态复位**：按住语音键（Fn 模式）后把焦点切到需要安全输入的密码框，等日志出现
   `HID FILTER phase=disabled`，松开语音键，再触发任意不含 Fn 的快捷键。
   该次 `SHORTCUT SEQUENCE phase=requested` 不应出现 `hardware_function_state=pressed`；
   应看到 `hardware_function_state=unobserved`，且逐事件的 `event_function=false`。
3. **Help 位**：若键盘有 Help / Insert 键，用它触发一次快捷键，逐事件 `event_flags` 不应含
   `4194304`（`0x400000`）。没有该键可跳过，本次不把它当作已验收项。
4. **诊断分类**：录一个只有 End 或 Forward Delete、没有修饰键的快捷键并触发一次，
   应出现 `primary_kind=end` / `primary_kind=forward_delete` 的请求行、逐事件行和观察行。
5. 回归对照：Command + L、Control + 方向键、裸方向键、语音 Fn 与长按连发保持原行为。

### 判定口径

- 复位后真实按住的 Fn 不再被信任，直到再次按下 Fn；这是刻意的取舍，日志里表现为
  `hardware_function_state=unobserved`。若用户在此期间仍期望 Fn 组合生效，属于已知边界。
- `HID FILTER phase=disabled` 本身不是失败，只说明监听中断过；必须结合紧随其后的
  `phase=requested` 状态字段判断有没有留下失效状态。
- 观察行只说明事件到达会话监听点并被放行，不代表目标 App 已执行。

### 自动化

`swift test --disable-keychain --filter 'ShortcutLifecycleTests'` 通过 35 项，覆盖禁用后复位、
Help 位不并入、大小写锁定保留、Fn 层键位分类与裸 End 的完整事务；
`swift test --disable-keychain` 通过 1085 项、79 个套件。
这些结果只证明宿主投递的 flags 与日志字段，Apple 芯片真机、实体键盘 Fn 与实体
Help 键仍待用户验收。

## 2026-10-24 Control 方向键诊断

适用分支：`codex/shortcut-system-diagnostics-20261024`。
本次仅增加日志，不改变事件标志、顺序、防抖或按键映射。

1. 使用包含本次提交的正式签名候选包，记录来源提交、版本、Build 和 macOS 版本。
2. 确认输入监控与辅助功能权限已授权。连接 RC003，退出按键捕获模式。
3. 用实体键盘 Control + Up 建立调度中心对照。关闭调度中心。
4. 下键绑定同一组合，单次按下后至少等待 1 秒。重复 3 次，分别记录是否打开。
5. 快速按下、松开 5 次。把 `awaiting_stable_release` 与实际投递分开统计。
6. 普通按键、组合动作、键位方案三个入口分别执行第 4 步。
7. 从 App 日志菜单保留该时间段日志。加密日志由受控支持流程读取。

按 `SHORTCUT SEQUENCE operation_id` 查找请求、逐事件提交和唯一终态。
请求的 `primary_kind=arrow_up`、`requested_flags` 与配置应一致。
`event_kind` 应依次为 modifier_down、key_down、key_up、modifier_up。
逐事件记录生成时的 Fn/NumericPad、实际 flags、提交结果和时间戳。
`SHORTCUT OBSERVATION correlation=matched` 使用操作号、事件序号和时间戳关联主键。
时间戳为零、变化或重复时，输出 `correlation=unavailable operation_id=unknown`。
此时仅观察本进程标记的 Control 方向键，不按相邻顺序强行关联。
观察只说明事件到达会话监听点且被本过滤器放行，不代表系统动作执行。
`flags_match=false` 表示观察到的白名单属性与提交前不同。
`HID FILTER phase=started|start_failed|disabled|reenable_requested|stopped` 说明监听边界。
没有观察记录时，先检查监听状态；不得直接判定系统拒绝。
超过 2 秒或超过 64 项的登记不保证关联；未观察不输出假超时失败。

失败判定：无法配对请求和终态、主键缺少提交记录、Control 方向键正常回放缺观察记录、
记录实体键盘内容、重复终态、修饰键残留，或把 submitted/observed 当作用户成功。
Control + Left/Right/Down、Command + L、裸方向键、语音 Fn 和现有长按连发应保持原行为。
自动化覆盖正反路径、属性差异、关联及日志隐私；实际系统事件与调度中心尚待真机验收。

本轮 `swift test --disable-keychain --filter 'ShortcutLifecycleTests|KeyboardEventSuppressorTests|RemoteButtonsTests'`
通过 164 项；`swift test --disable-keychain` 通过 988 项及另 4 项 XCTest。
`SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh` 通过 48 项；公开 Debug 构建与仓库边界检查通过。
这些结果不代表原始调度中心问题已修复。

## 范围与准备

适用分支：`codex/integrate-pr361-modifier-side`。现有普通自定义组合无需重新录入；只有需要区分左右侧的组合需要在候选版重新录入一次。准备具有辅助功能权限的正式签名候选包、真实遥控器、实体键盘、至少两个 App 和两个 Codex 会话。不要用未签名本地构建替换用户安装版本。

## 2026-10-20 原生方向键附带Fn回归

候选分支：`codex/fix-shortcut-navigation-fn-20261020`。
根因见 [执行阶段伪Fn记录](../Bugs/2026-10-20-shortcut-inherits-navigation-function.html)。

1. 普通按键页将遥控器下键配置为右Command+L，不关联专用方案。
2. Chrome前台触发下键。地址栏应获得焦点；网易云前台触发应切换喜欢状态。
3. 改为Command+Option+B，Chrome应打开书签管理页。恢复原配置。
4. 在方案中分别配置相同快捷键，保存、退出和重启后重复。
5. 明确配置Fn组合，确认Fn按下与松开均发送，不继承原生方向键的伪Fn。
6. 实体Fn先按住再触发遥控器。应保留真实Fn，松开后再触发不得带Fn。
7. 重启监听，并测试启动前已按住Fn和同时按松实体键的边界。
8. 继续回归语音Fn、左右修饰键、按住连发和普通方向键。

修复前6个断言失败；修复后16项生命周期测试和完整922项测试通过。
新日志仅记录`hardware_function_state`和`hardware_function_filtered`，不记录键码或内容。
请求和终态仍共用operation_id；投递成功不代表第三方App已响应。
本轮最终local包已通过构建、资源、签名和verify-app检查。
用户确认普通按键页下键右Command+L在Chrome和网易云均生效。
组合动作、方案入口与其余真实用例仍待确认。
253或254失败结果保留为修复前证据。

三类入口扩展：普通按键、组合动作的单步/整组/嵌套步骤、方案直接快捷键及方案组合动作分别复测。
私有组件通过宿主窄回调投递，旧宿主缺少能力时明确报错，旧构件仍可被新宿主识别。
18项生命周期测试覆盖1248种配置，另有2项宿主桥接测试。
公开924项、新接口源码集成935项测试和48项自检通过。
该矩阵覆盖13个代表键、32种修饰键组合和3种侧别。
它不代表所有App或所有可能快捷键已逐一实测。

## 2026-10-19 修饰键回显回归

当前候选分支：`codex/profile-clicks-20261019`。
单次同步事务读取一次物理修饰键快照，避免将合成事件回显当作物理按住。
旧版测试中的“实时快照一定纯物理”假定已撤销。
开始前已按住的实体键仍须保留；事务内同时按松实体键的竞态待实机检查。

1. 网易云中选择一首未喜欢的歌曲，先用实体键盘验证 Command+L。
2. 恢复歌曲状态，再用真实遥控器触发同一快捷键，检查喜欢状态可见变化。
3. 对 Command+Option+L 重复；分别保持网易云前台及允许全局快捷键的后台状态。
4. 连续触发不同组合各 20 次，随后输入普通文本，不得粘住 Command 或 Option。
5. 重复本手册 Control+Tab、Command+Tab、左右侧别、实体键并发及权限恢复用例。
6. 使用独立测试数据。结束后恢复歌曲与播放状态，不把用户数据写入回归文件。

自动化已覆盖合成回显、非修饰状态位、最终释放和下一次调用恢复。
受控系统热键接收器可接收两次生产序列；这不能证明网易云已响应。
没有最终私有二进制宿主或真实遥控器证据时，保持候选状态。
见 [修复记录](../Bugs/2026-10-19-shortcut-modifier-feedback.html)。

## 自动化

```sh
swift test --disable-keychain \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter 'ShortcutLifecycleTests|RemoteButtonsTests'
swift test --disable-keychain --skip-build
SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh
```

事件接收器替身检查协议，无真实按键注入。包含左右侧保存、右 Control/Option/Shift/Command 键码、失败后释放、有限重试、下一次调用恢复、另一侧实体键保留及日志隐私边界。同步事务没有异步取消/超时状态；不增加按住、延时或重复任务。

## 真实流程

1. 在 Codex 先用实体键盘 Control+Tab/Control+Shift+Tab 建立对照：松开 Control 后确认最近会话。用遥控器分别触发同样配置；预期单击完成选择，无须再按 Return。列表停留、方向错误、切换两次均失败。
2. 自定义 Command+Tab：两个普通 App 间连续切回 20 次，每次单击只切一次，切换器不滞留；重复全屏、多屏场景。内置 Command-Tab 仍应保持选择模式并允许确认退出。
3. Control+Option+主键以及 Shift+Command+主键：与实体键盘对照，目标动作只执行一次。测试普通 Command+C/V 等按下即执行的组合。
4. 测试无修饰 Return/方向键、单独左右修饰键、Fn/Command 语音按下与释放；应保持原行为。
5. 实体键盘先按住 Control，再触发 Control+Tab：不得合成该 Control 的松开，选择可保持到用户实际松键；同时按住 Shift/Option 等附加修饰键时按真实组合语义处理，不强制清除物理状态。重复在触发过程中按下实体修饰键，再手动松开，后续输入不得粘键。
6. 撤销辅助功能权限后不得发送事件；重新授权后复测。事件构造/注入失败只由替身覆盖；真实权限和 WindowServer 拒绝不能用替身成功代替。
7. 重启后旧快捷键仍存在，导入导出保持原格式，不要求重新录入。
8. 进入快捷键录入，分别录入左、右 Command + 逗号，并在映射摘要与编辑器中确认显示 `左⌘,`、`右⌘,`；对左右 Option、Control、Shift 重复。显示合并为通用符号、左右保存值相同或重启后侧别丢失均失败。
9. 在一个明确区分左右 Command 的测试 App 中，以实体键盘建立对照，再用遥控器连续触发右 Command + 逗号 20 次。每次只能触发右侧目标动作，前台 App 不应同时收到通用或左侧组合；出现漏触发、双触发、设置页等无关动作或后续输入粘住修饰键均失败。
10. 实体键盘按住左 Command 时触发右 Command 组合；目标侧仍应为右侧，遥控器动作结束后左 Command 保持到用户真实松键。左右互换后重复。

## 日志

从 App 的“文件 → 打开日志所在文件夹”收集测试时间段内的加密 `.rmlog`，交由受控支持环境解密后筛选 `SHORTCUT SEQUENCE`，按 operation_id 配对 requested 和唯一 completed。侧别组合的 requested 应为 `side_specific=true`；正常终态为 submitted，失败说明 reason/cleanup_failed。submitted_events 仅证明提交次数，user_visible_result=unknown 不代表测试通过。不得收集输入文本、会话标题、设备标识或私有数据。

## 验证边界

自动化可证明构造出的事件类型、顺序、左右设备位、清理和保存格式回归；不能证明目标 App 接受、WindowServer 实际切换、真正物理按键竞态、Intel 或私有模块整合。真实遥控器、区分左右侧的第三方 App、全屏/多屏和权限恢复均待人工验收；PR 在双架构 CI 与实际页面截图完成前不得合入。

## 2026-10-20 最终local包验收记录

公开集成源码：`02b9319dd55d395a8b1cdac229dd03f785025c6c`，工作区干净。
版本栏仍为2.0.0 Build 251，以本轮来源和local渠道区分。
使用ad-hoc签名，没有覆盖安装目录中的App。
保留正式会员判断，未启用免费测试绕过。

用户已确认：普通按键页下键右Command+L可聚焦Chrome地址栏，并切换网易云喜欢状态。
待确认：组合动作单步/整组/嵌套、方案直接快捷键、Chrome书签页、实体Fn与并发边界。
公开双架构CI通过。私有CI因GitHub账户账单问题未启动，不能按通过处理。

## Build 264 后的配置快捷键诊断

1. 用实体键盘建立 Chrome 主页 Command+Shift+H 的对照。
2. 在普通按键页、组合动作和键位方案分别配置同一组合。
3. 在目标 App 前台用小米遥控器触发。记录可见结果及时间。
4. 对 Command+Option+B、Command+L、Page Up/Down 重复。
5. 网易云的系统播放/暂停另行验证；不能把全局分发当作定向控制。
6. 收集该时段的本机加密 rmlog。Sentry 不上传这些逐事件明细。

筛选 SHORTCUT SEQUENCE 与 SHORTCUT OBSERVATION，按 operation_id 关联。
核对 requested_flags、hardware_flags、physical_flags 和 event_flags。
会话层 flags_match 只表示标志一致；user_visible_result 仍为 unknown。
Command 主键不写入日志，诊断类别统一为 command_shortcut。

系统播放筛选 SYSTEM MEDIA，并用同一操作编号查观察记录。
按下和松开应各提交一次；完成日志应有 submitted_events=2。
原生输入筛选 HID FILTER；via=owned_native_pair 表示提前松开已消费。
phase=arm_order 仅报告登记前的同码事件，不能证明设备来源。

原生事件时序回放必须覆盖：按下已拦截、原生松开先到、HID 松开后到。
迟到的 HID 松开不得留下新的待消费松开，也不得吞掉后续实体键盘事件。


## Build 264 后的音量事件对回归

候选适用范围：音量加、减自定义动作及默认映射。
准备真实小米遥控器，保留实体键盘音量键作为对照。
记录版本、Build、测试时间、遥控器型号和权限状态。

1. 在输入框前台，将音量减设为逗号，音量加设为普通自定义动作。
2. 每个键短按 20 次。每次只执行配置动作一次。
3. 每次松开后等待 2 秒。系统音量不得继续变化。
4. 长按后松开，再交替快速按加减各 10 次。
5. 保持自定义动作时，系统音量不得出现额外变化。
6. 将加减恢复默认。短按只调整一次，长按按既有速率调整。
7. 松开、断连、禁用映射或撤销权限后，连发必须停止。
8. 使用实体键盘音量键。按住可持续调整，松开必须停止。
9. 恢复权限和连接，再重复短按及长按。
10. 回归菜单、TV、方向键、返回键和已有快捷键。

任一松开后持续调节、额外音量变化或后续实体键失效均失败。
初次原生按下已放行时，候选仍可能调整一次音量。
这属于未完成的泄露验收，不能把“已停止持续调节”算作全通过。

从 App 菜单打开本地日志目录，收集对应时段的加密 rmlog。
由受控支持环境筛选 HID EDGE、HID FILTER 和 HID BUTTON。
reason=escaped_native_pair 表示保持已放行事件对完整。
phase=arm result=passthrough 表示不再登记该次原始边沿。
phase=arm_order 仍仅为时序证据，不证明事件来自哪台设备。

本轮自动化回放已覆盖原始故障顺序和既有过滤基线。
真实设备、系统最终音量与第三方输入框尚待人工验收。
