# 常用语本地测试

适用分支：`codex/common-phrases-docs-alignment-20261002`；产品行为以 [`PRODUCT_SPEC.md`](../feature/common-phrases/PRODUCT_SPEC.md) 为准。当前为本地候选，尚未合入 main 或完成真实设备验收。

## 准备

1. 使用本 worktree 的 `dist/SayAll.app`，退出正在运行的其他无线麦实例后启动该包。不要覆盖正式安装；此包为 Developer ID 签名的本地 App，不是公证发行版。
2. 在系统设置中确认辅助功能和输入监控权限；实体遥控器另需蓝牙权限。常用语不需要麦克风权限，不占用语音键。
3. 记录当前五个方向/OK 键及返回键映射；将一个普通按键（例如菜单键）的单击绑定到“打开常用语”。不要使用语音键。
4. 在按键动作列表中点击“打开常用语”旁的“调整常用语”，确认无独立常用语侧栏，页面最左侧为五键圆盘，中间为常用语库，右侧为编辑内容。五键默认为 OK=好的、左=继续、上=说清楚一点、右=按你的来、下=思路可以，我补充一点。
5. 打开一个普通可编辑输入框，放置光标并取消选区。仅使用脱敏测试内容；先复制一段可辨认的测试文本，以便检查剪贴板恢复。

## 核心流程

| 步骤 | 操作 | 预期与失败判定 |
| --- | --- | --- |
| 1 | 在目标 App 中按已绑定的打开键 | 宽 300pt、80% 不透明度的浮层在屏幕居中出现；无左上角标题，顶部两行居中的 14pt 操作说明，方向键一圈、OK 居中。目标 App 和输入光标保持。激活无线麦、焦点丢失、几何或说明不符均失败 |
| 2 | 每次重新打开面板，分别按 OK、左、上、右、下并松键；另逐个鼠标点击五个位置 | 按下/点击即关闭圆盘，对应完整句插入当前光标处，原内容保留，不发送、不回车。关闭导致本次插入取消、等待松键才关闭、只出现短显示、重复插入或自动发送均失败 |
| 3 | 给“左”配置双击和长按，再打开面板按一下左并按住，最后松键 | 按下即关闭并开始插入，不等手势窗口；关闭后同次按住不连发，松键不透传原映射。首次按键丢失、明显等待、额外动作或持续重复均失败 |
| 4 | 快速反复打开、选择左/上/OK 并松键（每条都重新打开） | 每次调用至多一条，顺序一致；插入事务自然恢复剪贴板。没有重新打开时下一次完整按下恢复原映射。关闭取消当前插入、松键透传、多条或乱序均失败 |
| 5 | 按返回并松键，随后逐一试原有映射 | 面板关闭；返回按下/释放均不传给目标 App；所有原映射恢复。返回跳页、延迟残留动作或映射被改写均失败 |
| 6 | 面板打开时切换前台 App、让无线麦从前台转入后台、锁屏/休眠或断开该遥控来源 | 面板关闭，未提交的插入取消。重新连接并打开后第一次按键可用；新 App 收到旧队列文字、旧面板残留或首次失效均失败 |

## 剪贴板、失败与恢复

- 正常插入后，在另一普通输入框手动粘贴：应得到插入前复制的测试内容。原剪贴板包含图片/多种类型时也须保留；恢复为空或错误内容即失败。
- 在插入后的短时间内主动复制新的测试内容：新复制内容应保留，不得被旧快照覆盖。事务当前等待约 250 ms 后检查剪贴板归属并恢复；这不能证明所有第三方 App 均已完成读取，须分别实测。
- 对无输入框、只读页面、密码/安全输入、Token 输入框和非空选区分别测试：圆盘立即关闭，居中失败提示显示约 3 秒；文字不得落到别处，剪贴板不变。无法通过公开辅助功能确认焦点、编辑性或选区时，也应明确拒绝。
- 暂时关闭无线麦的辅助功能权限再试：明确提示授权；重新授权后，同一流程恢复。不得把“发送了 Cmd+V”当成文字上屏成功。
- 在上一条剪贴板事务仍在恢复时重新打开并选下一条：圆盘立即关闭，两条仍按顺序提交并恢复原剪贴板。重新打开后按返回取消时，已提交事务仍恢复，尚未提交队列取消。

## 用户内容

1. 进入调整页，先点击圆盘一个位置：只高亮该位置并显示其当前内容，不修改任何分配。再点击常用语库中的条目：仅该位置更新且立即保存在本机；其他四键保持。切换另一个位置再选择内容，结果必须独立。没有先选位置时，点击库条目只编辑内容，不改变五键分配。点击圆盘或库条目不得向其他 App 插入文字。
2. 在右侧编辑短显示与完整句并“保存更改”；修改内置条目产生本机用户副本，不回写源 Markdown。新增后保存，再点圆盘位置和新条目完成分配，随后在目标 App 打开面板使用。只改变面板分配，不改普通遥控映射。删除已分配内容后该位置应显示未分配，重新选内容能恢复。
3. 拖动条目左侧手柄到另一条目，内容移动到该行，沿途条目顺序保留，五键分配不变；上移/下移按钮继续可用。关闭并重新启动 App：顺序、内容与分配保留。
4. 删除条目：分配该条目的键显示未分配，按下时圆盘关闭，并显示约 3 秒的未分配提示；其他条目和普通按键配置保持。
5. 导出 JSON、修改一条测试内容、再导入原文件：常用语恢复，普通设置不变。导入错误 JSON、重复 ID、未知版本或无效绑定：明确报错，保留原数据。取消文件选择不会改数据。
6. 恢复默认按键映射后，常用语内容仍保留。重新绑定打开动作可继续使用。
7. 搜索短显示或完整句，结果可选择并分配；清空搜索恢复全部条目，当前键位与其他分配保持。内容编辑必须点击保存，分配选择立即保存；重启后两者都保留。
8. 点击“返回”后回到原有按键与单击/双击/长按编辑上下文；进入其他侧栏页面，再返回按键，窗口几何不改变。调整入口只打开编辑页，不绑定“打开常用语”；点击打开动作才修改当前按键绑定。动作目录五组平级，各筛选仅显示对应组；具体 App 始终平铺，打开自定义 App 为该组最后一项；打开/调整常用语与普通动作的高度、圆角和描边一致。
9. 点击五个筛选按钮文字周围、边框内的留白：每次均切换到对应组；普通动作与调整常用语按钮同样覆盖完整边框内区域。调整页顶部“返回”与右侧标题同一行垂直居中；点击返回按钮边缘留白也应回到原按键编辑上下文。任一按钮只能点文字、返回点击区域小于 72×44pt 或标题另起一行均失败。浮层顶部两行说明为“按方向键和OK键插入对应常用语”和“按返回键关闭面板”，14pt、整体居中，文字不得与关闭按钮重叠。
10. 对照 `Screenshots/common-phrases/editor-alignment-20261003/reference.png`：常用语库使用紧凑描边行、蓝色选择态、拖动手柄和独立键位标签；新增与搜索图标可见。右侧短显示为单行框，中文/英文完整句为多行框（空内容也保留高度），保存按钮蓝色，删除按钮带垃圾桶图标。两个完整句中输入换行、修改内容并保存，再切换条目回来检查换行仍保留；默认窗口可访问保存，800×650 下编辑区向下滚动可访问保存和提示。中文字号低于 12pt、输入框塌缩为单行、按钮不可访问或换行丢失均失败。

## 来源、权限和第三方矩阵

分别执行核心流程与失败恢复，不得以一项通过代表其他项：

| 维度 | 独立用例 | 当前真实验收 |
| --- | --- | --- |
| 实体 | 小米 RC001、RC003；Siri Remote；Chromecast（仅硬件存在且支持的按键） | 待用户实测 |
| 移动 | iPhone 附近连接、Apple Watch、网页版；旧 command 与 buttonEventsV1 两类协议入口；连接正常/断开/重连 | 待用户实测 |
| 多设备 | A 打开面板，B 按方向键；B 不得操作 A 的面板；A 断开后 A 面板关闭 | 待用户实测 |
| 目标 | 微信、豆包、浏览器普通文本区、Electron 编辑器、原生文本区 | 各自待实测；不承诺全部自定义编辑器可用 |
| 状态 | 无线麦前台/后台、目标前台/切换、辅助功能已授权/拒绝、系统安全输入开启 | 待用户实测 |
| 显示 | 中文/英文 × 浅色/深色；800×650 和默认窗口 | 静态截图与真实窗口交互分开记录 |

## 稳定基线回归

- 未绑定打开动作时，所有原有按键、单击/双击/长按、按住连发与快速连续按保持。
- 面板关闭前后，语音键极速按下/释放、快速连续语音、异常中断恢复及正常尾音完整保持；RC003 普通语音仍覆盖无需主动 MIC_OPEN 的 STREAM_START → AUDIO → STREAM_STOP。
- App 切换器、绑定编辑捕获、Onboarding 按键阻断、多设备选择、手机/网页原有会话均保持。无需重跑或更改已完成的 Onboarding 配置。
- 清除/导入/导出常用语不得清除按键映射、语言、音频设备、转写历史或会员状态。

## 日志与验证边界

在“设置”的诊断与日志区打开本次日志，按发生时间核对 `COMMON_PHRASES`：

- `PANEL`：opened / closed 与关闭原因。
- `INSERT`：进程内 operation_id、请求、前置检查、paste submitted/failed、clipboard restored/user_copy_preserved、唯一 completed 结果与耗时；排队取消明确记录 cancelled。
- `EDIT` / `IMPORT` / `EXPORT`：操作类型、结果与失败/取消原因；不得包含常用语正文、剪贴板内容、路径、输入框文字、App 身份或设备身份。
- `EDITOR` / `POSITION`：编辑页打开/关闭；进程内 position operation_id、键位选择请求与完成。仅选择位置不应出现 `EDIT action=assign`；从库选择内容后才出现分配保存，失败时保持原分配并提示。
- `result=submitted` 和 `diagnostic_boundary=external_text_unobserved` 只证明提交了粘贴；请另行确认目标输入框真实上屏。不要把日志中的“入队”或“提交”作为验收成功。

自动化：`CommonPhraseTests` 已覆盖资源四类非法输入、默认键位、用户副本与重启、资源更新、错误导入、来源隔离、快速按与松键消费、HID 手势前认领、剪贴板多类型恢复、新复制保护、粘贴失败、取消与恢复。公开宿主全部 796 项、注入全部遥控适配器的 852 项测试已通过；自动化使用模拟按键与测试剪贴板，不能替代真机。

2026-10-03 圆盘与位置优先交互验证：公开全量 796 项、私有遥控适配器集成全量 852 项通过；最终按钮宽度适配及交互入口调整后，相关 62 项测试再次通过。日志分别为 `dist/common-phrases-circle-full-tests.log`、`dist/common-phrases-circle-integrated-tests.log` 和 `dist/common-phrases-circle-tests-final.log`。

通过生产 `SettingsView` 的独立测试数据窗口实际点击验证：相邻调整入口、无独立侧栏；未选位置只查看内容；只选位置不写分配；选择条目后只更新选中键位；切换位置独立分配；编辑需保存且圆盘同步；搜索/清空；导出取消；返回保留确定键单击编辑上下文，再进入保留已保存内容。800×650 实际窗口逐一点击按键、回眸、连接、设置入口，页头与导航保持；此尺寸是压力测试入口，生产默认/最小窗口仍为 1020×772。窗口使用独立 UserDefaults，不启动硬件，不改用户配置。

最终本地包 `dist/SayAll.app` 通过原生构建、资源门禁及 Developer ID（Team `L3QHLDRPAY`）深度严格签名检查，并已正常启动且进程保持。构建记录为 `dist/common-phrases-circle-app-build-final.log`。真实遥控器、第三方输入框文字上屏和语音实机基线仍待用户验收；启动进程和界面点击不证明这些路径通过。本功能保持候选，TODO 不勾选完成。

### 2026-10-03 列表与编辑样式对齐

本轮相关 63 项测试（2 suites）通过，覆盖新增的跨多行排序、其他条目相对顺序、五键绑定与重启持久化。命令为 `swift test --disable-keychain --scratch-path /private/tmp/remote-mic-swiftpm/common-phrases-debug --filter 'CommonPhrase|SettingsPageRegression'`，记录为 `dist/common-phrases-editor-alignment-tests-final.log`。上文 796/852 项为此前圆盘版结果，本轮没有重新执行全量测试。

最终 `dist/SayAll.app` 完成 Release 构建、资源校验和 Developer ID 深度严格签名验证；重新启动后通过 `pgrep` 确认本 worktree 的正常 App 进程存在。记录为 `dist/common-phrases-editor-alignment-build-final.log` 和 `dist/common-phrases-editor-alignment-startup.log`。仍为 all-remotes、本地渠道、未公证的本机测试包。

生产设置页使用独立 UserDefaults 实测：选上键后显示蓝色列表选中态；中文和英文完整句各输入两行，保存后切到 OK 再切回上键，换行与分配均保留；原下移按钮移动条目后，其他条目相对顺序及五键分配保持。测试副本不启动硬件，也不改真实用户配置。

拖放排序的数据逻辑已通过自动化，但原生指针自动化未完成有效命中，不能宣称拖放交互通过；须按“用户内容”第 3 条实测。800×650 静态页面中保存/删除位于滚动下方，该压力尺寸的实际滚动也待实测。真实遥控器、第三方文字上屏及语音稳定基线仍待验收。

最终证据在 `Screenshots/common-phrases/editor-alignment-20261003/final/`：16 张生产离屏 PNG（中/英 × 浅/深 × 两尺寸的页面与面板）及 2 张实际交互 JPEG。原始参考图、初版记录和最终证据共 36 张图的格式、尺寸、字节数及 SHA-256 均已核对，见同目录上级的 `manifest.json`；初版记录仅作历史证据。

本轮文件必要性：`CommonPhraseSettingsView.swift` 对齐卡片、列表、搜索、键位标签、多行编辑框与按钮，并接入手柄拖放；`CommonPhraseStore.swift` 改用插入式移动以保持跨行排序的其他条目顺序；`CommonPhraseTests.swift` 验证其持久化与绑定；两种语言资源同步新增/删除按钮文案；产品规范、TODO 与本文同步样式和验收边界。黑色五键圆盘及位置优先分配逻辑保持。


### 2026-10-03 五组平级与一次选中关闭

相关 186 项测试（3 suites：Common phrases、SettingsPageRegression、RemoteButtons）通过，命令为 `swift test --disable-keychain --scratch-path /private/tmp/remote-mic-swiftpm/common-phrases-debug --filter 'CommonPhrase|SettingsPageRegression|RemoteButtons'`，记录为 `dist/common-phrases-single-selection-tests-final.log`。控制器测试使用独立剪贴板与模拟粘贴：验证按下即隐藏圆盘、按住重复与松键仍消费、下一次未打开时恢复原映射，以及第一条剪贴板事务仍在恢复时再次打开选择第二条，最终两条都提交且恢复原剪贴板。失败模拟确认圆盘关闭并产生输入不可用提示；这些结果不能证明第三方真实上屏。

HID 回放验证面板内绕过双击等待、关闭后恢复原映射。首次回放测试未复用生产 `onWillOpen` 的取消边界，残留旧手势导致断言失败；对照现有生产链路后，将回放补齐同一取消调用，最终通过，未修改 HID 或语音实现。

最终 `dist/SayAll.app` 的 Release 构建、资源校验及 Developer ID 深度严格签名通过，记录为 `dist/common-phrases-single-selection-build.log`。本包继续为 all-remotes、本地渠道；包含小米公开宿主、Siri Remote、Chromecast、Mac Remote，未注入 AI、组合动作、键位方案与会员资源，仅供当前 Mac 测试，不是公证分发包。

另一无线麦实例退出后，正常启动本轮 `dist/SayAll.app`，通过 `pgrep` 确认本 worktree 的 App 进程保持，记录为 `dist/common-phrases-single-selection-startup.log`。没有结束或覆盖其他任务的 App；正常启动只证明本包进程启动，不证明真实输入与语音路径通过。

在生产设置页的独立 UserDefaults 窗口（800×650）实际点击五个筛选项，各组独立；具体 App 无折叠开关，自定义 App 为最后一项，选择后仍出现原目标 App 配置。打开常用语写入当前测试按键，调整常用语仅进入编辑页，返回后该绑定和编辑上下文保留。逐一点击按键、回眸、连接、设置入口并查看实际窗口截图，侧栏、页头与窗口几何保持。测试不启动硬件、不改真实配置。

8 张中/英 × 浅/深 × 两尺寸的动作页及对应面板 PNG 已逐张或按相同字节核对；面板为 300×360pt，无标题，顶部说明 16pt，整体不透明度 80%。实际窗口截图与原始参考图保存在 `Screenshots/common-phrases/single-selection-20261003/`，格式、尺寸、字节数和 SHA-256 见 `manifest.json`。800×650 英文筛选和较长动作允许尾部截断，完整名称由辅助功能保留。

编辑区滚动自动化未确认充分滚动，保存按钮在压力尺寸截图中仍部分位于底部，故仍待用户实测，不能将本轮导航检查当成滚动通过。原生拖放、实体遥控器/移动来源、第三方文字上屏及语音稳定基线继续待验收；浮层居中和透明度有实现与静态证据，仍需在实际目标 App 和多屏环境确认。

本轮文件必要性：`RemoteButtons.swift` 调整分类和自定义 App 末项；`SettingsView.swift` 平铺五组、移除折叠状态、复用普通网格按钮样式；`CommonPhraseStore.swift` 选中即结束一次路由但保留松键消费；`CommonPhrasePanel.swift` 缩小居中、顶部说明、关闭后保留本次粘贴与失败提示；两种语言资源同步顶部说明；三个现有测试文件覆盖分类、路由、控制器与页面回归；中英设计规范、产品规范、TODO 与本文同步公开行为和验证边界。TODO 保持候选。

### 2026-10-03 顶部文案、二级页导航与按钮点击区域

相关 186 项测试（3 suites）通过，命令仍为 `swift test --disable-keychain --scratch-path /private/tmp/remote-mic-swiftpm/common-phrases-debug --filter 'CommonPhrase|SettingsPageRegression|RemoteButtons'`，记录为 `dist/common-phrases-navigation-tests-final.log`。本轮只改展示和命中形状，未改插入、来源认领、硬件或语音路径。

最终 `dist/SayAll.app` 已通过 Release 构建、资源门禁与 Developer ID（Team `L3QHLDRPAY`）深度严格签名校验。记录为 `dist/common-phrases-navigation-build.log`；正常启动后确认本 worktree 的 App 进程存在，见 `dist/common-phrases-navigation-startup-final.log`。仍使用 all-remotes、本地渠道，未公证，仅供当前 Mac 测试；未注入 AI、组合动作、键位方案与会员资源。

生产离屏截图覆盖按键动作页与调整页的中/英 × 浅/深 × 1020×772、800×650，共 16 张页面及对应面板。页面逐张查看；面板按原字节摘要确认只有两种语言的 2 个不同结果，均查看。顶部两行说明为 14pt、相对整个 300pt 面板居中，与关闭按钮不重叠；返回为 72×44pt、16pt，仅显示“返回”，与右侧标题垂直居中。所有原图、生产截图及交互诊断图的格式、尺寸、字节数与 SHA-256 见 `Screenshots/common-phrases/navigation-hit-area-20261003/manifest.json`；其中 `final/` 是生产离屏证据，`interactive*` 为各次交互的状态或诊断记录，渲染器退出时的自动截图不一定保持初始页面。

800×650 独立 UserDefaults 窗口实际通过辅助功能按钮动作验证五个筛选切换、打开调整页、“返回”回到按键页，以及按键、回眸、连接、设置四个侧栏入口；不启动硬件、不改用户配置。当前轮从调整页返回的导航通过，但保留编辑上下文的重复检查在交互渲染器达到 300 秒边界后未完成，此项保留前轮结果，不宣称本轮重新通过。退出后出现的独立副本普通窗口已关闭，并按其精确可执行路径结束该副本，没有结束其他 worktree 的进程。

边框内完整点击区域通过 SwiftUI label 的 `contentShape` 覆盖筛选胶囊与普通动作圆角形状，返回也覆盖 72×44pt 全形状。坐标点击自动化未可靠命中筛选留白，不能把辅助功能动作通过当成边缘点击验收；请按“用户内容”第 9 条在本机手动验收。800×650 编辑区滚动、原生拖放、真实遥控器与移动来源、第三方文字上屏、语音稳定基线仍待实测。TODO 保持候选。

文件必要性：`CommonPhrasePanel.swift` 调整居中说明和字号；`SettingsView.swift` 扩展筛选及动作按钮命中形状；`CommonPhraseSettingsView.swift` 将返回与标题同行并扩大返回区域；中英文资源同步两行说明与返回短文案；中英文设计规范、产品规范、TODO 与本文同步行为和验证边界。未实现的未来要求继续保留。

### 2026-10-03 PR 主线同步与验收检查

PR #558 提交前已同步 `origin/main` 的 `eb96536cca4ed519ced7db6d5d3b5a1ab13cae09`，产品源码提交为 `86e2a42ccd7bbd9514c3b9545fae405e4defd9c1`。公开全量 800 tests / 61 suites 通过，项目自检 48 passed / 0 failed；治理、仓库边界、变更 Markdown 相对链接及 `git diff --check` 通过。首次全量中发布 control-plane fixture 以 141 退出，随后该项单独复跑及全量复跑均通过，保留首次失败日志；不修改与本功能无关的发布实现。

记录为 `dist/common-phrases-pr-full-tests.log`、`dist/common-phrases-pr-release-fixture-retry.log`、`dist/common-phrases-pr-full-tests-retry.log` 和 `dist/common-phrases-pr-selftest.log`。同步主线后重新构建的 all-remotes 本地包通过 Release、资源与 Developer ID 深度严格签名，见 `dist/common-phrases-pr-app-build.log`；本轮只启动独立 UI 验证副本，不宣称普通 App 启动或实机验收通过。

生产 `SettingsView` 独立 UserDefaults 窗口以 `1020×772` 内容尺寸验证：五组筛选、具体 App 平铺且自定义 App 为末项、进入调整页、返回保持确定键单击编辑上下文，以及按键/回眸/连接/设置四个侧栏入口。操作通过辅助功能按钮动作；页面、页头和侧栏已查看，窗口几何保持。指针点击调整按钮右侧留白没有产生可确认的页面变化，不能将辅助功能操作通过当作边缘命中通过，也未据此猜测或修改实现；该项仍须按本手册用户步骤验收。

最新中/英 × 浅/深的两种页面及圆盘生产截图、实际窗口原始 JPEG 位于 `Screenshots/common-phrases/pr-review-20261003/`，共 25 张图片的格式、尺寸、字节数和 SHA-256 见 `manifest.json`。截图来自上述产品源码，随后证据提交不改变产品代码。真实遥控器/移动来源、第三方文字上屏、语音稳定基线、原生拖放、编辑区滚动和多屏浮层仍待用户验收；PR 保持 Draft，TODO 保持候选。

## 本轮文件与证据

| 文件 | 本次变化与用途 |
| --- | --- |
| `CommonPhraseStore.swift` | 常用语数据、用户副本、本机持久化、导入校验与来源认领；导入修改过的内置条目也转为用户副本，重启后保留 |
| `CommonPhraseInserter.swift` | 公开辅助功能元数据检查、串行粘贴、剪贴板恢复与脱敏终态日志 |
| `CommonPhrasePanel.swift` | 共用黑色五键圆盘、非激活面板、返回/切换/断连/锁屏关闭、排队取消 |
| `CommonPhraseSettingsView.swift` | 左侧先选键位、中间选常用语完成分配、右侧编辑；新增、删除、排序、搜索及系统文件备份导入导出 |
| `RemoteButtons.swift`、`KeyboardInjector.swift` | 新增稳定宿主动作 ID、动作分类与非重复语义，纳入内部动作分发 |
| `BridgeAppModel.swift`、`HIDRemoteMonitor.swift` | 实体、手机/Web 的 command 和 buttonEventsV1 入口在手势前认领，Apple Watch 面板来源单独隔离，原有语音生命周期不改动 |
| `SettingsView.swift`、`SettingsScreenshotRenderer.swift` | 动作旁的调整入口、内部编辑页与返回导航；生产截图及最长 300 秒的交互验证入口使用独立设置数据，不启动硬件 |
| 两种语言的 `Localizable.strings` | 动作、设置、面板和失败反馈的语义文案 |
| `scripts/generate-common-phrases.py`、`scripts/build-app.sh`、`scripts/verify-app.sh` | 从唯一 Markdown 源生成并严格核对 Bundle JSON，错误源阻断构建 |
| `CommonPhraseTests.swift`、`SettingsPageRegressionTests.swift` | 资源、持久化、来源与边沿、HID 回归、剪贴板事务及侧栏顺序验证 |
| `PRODUCT_SPEC.md`、`built-in.md`、`feature/README.md`、`TODO.md`、`DOCUMENTATION.md`、本文 | 同步实现状态与测试入口，保留未来要求和未验收状态 |
| `Screenshots/common-phrases/implemented-20261003/` | 最终 16 张生产离屏 PNG（中/英 × 浅/深 × 两尺寸的页面与面板），6 张实际窗口交互 JPEG；原始字节、尺寸和 SHA-256 见 `manifest.json`。旧截图保留作历史记录 |

公开全量测试命令：`swift test --disable-keychain --scratch-path /private/tmp/remote-mic-swiftpm/common-phrases-debug`。集成测试另显式提供 Siri Remote、Chromecast、Mac Remote 的本地 Package 路径，并使用独立 scratch path；共 852 项通过。

本地包使用 all-remotes 配置，包含小米公开宿主、Siri Remote、Chromecast 与 Mac Remote 接收适配器，不包含 AI、组合动作、键位方案及会员资源；iOS/Watch/Web 客户端仍由独立项目维护。私有键位方案中的宿主动作入口已接通代码，但本包未注入该私有功能，不能视为方案实测通过。
