# 自定义快捷键修饰键生命周期测试

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
