# 首次使用设置向导测试手册

> 执行本手册或修改 Onboarding 前，先完整阅读跨平台产品规范 [`feature/first-run-onboarding/PRODUCT_SPEC.md`](../feature/first-run-onboarding/PRODUCT_SPEC.md) 和 [macOS 平台适配](../feature/first-run-onboarding/platform-macos.md)。未来 Windows 测试应从同一产品规范出发，并使用 [Windows 平台适配](../feature/first-run-onboarding/platform-windows.md) 建立独立测试手册。

## `.sayall` 文件打开与首次 Onboarding

适用范围：用户首次安装 SayAll 后，从 Finder 双击键位方案 `.sayall` 文件。

1. 准备一个有效的 `.sayall` 文件，并确认 SayAll 尚未完成 Onboarding。
2. 双击文件。预期：SayAll 启动并显示 Onboarding；文件请求不会立即写入配置。
3. 完成 Onboarding。预期：向导结束后自动进入“键位方案”页面的导入预览，并显示该文件的内容。
4. 取消导入。预期：方案不写入，用户回到“键位方案”页面。
5. 确认导入。预期：方案写入当前配置，并显示导入结果。
6. 在 SayAll 已运行且 Onboarding 已完成时再次双击文件。预期：直接进入“键位方案”页面的导入预览。
7. 先切到“连接”或“设置”，再双击文件。预期：进入“键位方案”并显示预览。
8. 取消后再次双击同一文件。预期：重新显示预览，取消操作不写入配置。
9. 打开现有 `sayall://launch` 回流。预期：保持原回流行为，不触发文件导入。

请求仅在本次 App 进程内暂存。退出 App 后，应再次双击文件。同次打开多个文件时只处理首个 `.sayall`；向导期间再次打开文件时以最新请求为准。

失败判定：Finder 不能把 `.sayall` 交给 SayAll、Onboarding 完成后文件请求丢失、未完成 Onboarding 时绕过向导写入配置、取消后仍写入方案，或重复打开造成重复导入，均判定失败。

自动化可以验证文件类型声明、请求暂存和清理。真实 Finder 双击、首次安装 Onboarding、导入预览和保存仍需在签名安装包上完成。

2026-10-19 审查修正：生产 `SettingsView` 挂载测试已复现旧版漏读请求；修正后覆盖挂载前请求、挂载后请求和同文件重试。文件先切到“键位方案”，再由该页面挂载后的任务提交；不改变现有导入预览、取消、保存和会员校验。构建和自动化不代表真实安装验收。

本轮公开完整测试 902 项、私有完整测试 910 项通过。最终定向测试公开和私有各 5 项通过，另覆盖未完成向导时保留请求，以及拒绝非文件 URL 和其他后缀。市场校验、Apple Silicon Release 构建和 `verify-app.sh` 通过。生产交互入口使用隔离数据，实际查看全部绑定并取消，列表仍只有默认方案。中文浅色截图为 [导入预览](../Screenshots/design-drafts/sayall-file-import/import-preview-macos-zh-light.jpg)，JPEG、2040 × 1544，SHA-256 为 `fc89e381433628332c618ac932c2939d23ec4a1e2211bd2d2588a600630c76e8`。缺少深色和完整向导截图，以及签名安装、真实完整向导、确认保存、重启重读和会员状态验收；PR 保持 Draft。详见 [审查记录](../Bugs/2026-10-19-sayall-file-import.html)。

## 2026-10-24 连接页去掉重复下载入口、权限勾选项改统一样式、App 统一叫 iOS App

适用分支：`codex/onboarding-membership-sheet`。三处都只动呈现与文案，不改 `OnboardingFlowPolicy`、不改权限判定、不改连接链路。

1. **「连接 iPhone 或 Apple Watch」页删掉左栏的下载按钮。** 原来标题下面紧跟一个 `onboardingLink(id: "iphone.install")` 按钮「从 App Store 安装无线麦 SayAll」，而同一屏右栏已经是同一件事的入口（App Store 下载二维码 + 官方徽章）。左栏再去掉一层，正文下面直接接「等待 iPhone 或 Apple Watch」状态卡。文案键 `onboarding.apple_companion.install` 中英同步删除，不留死键；`remotePageDoesNotRepeatTheAppStoreInstallLink()` 反向锁定：`iPhoneRemoteContent` 段落里不得再出现 `onboardingLink` 或 `iOSAppStore`。
2. **权限页第 4 项的状态标记改成和其余三项一样的圆形。** 原来是自绘的 20pt 圆角方框，和上面三个 19pt 圆勾并排时会被读成两类不同控件。现在统一用 `checkmark.circle.fill` / `circle`，19pt，绿色 / `secondary`。整行的强调底色、描边和「整行可点」都不变。`iphoneAppPermissionRowUsesTheSameStatusMarkAsOtherPermissions()` 锁定形状与尺寸，并禁止 `checkboxMark` 这个自绘函数再长回来。
3. **同一个 App 统一叫 iOS App。** 文案里既有「iPhone App」又有「iOS App」，iPhone 只是它运行的其中一台设备，写死设备名会把 iPad 用户挡在门外。

### 文案改动（中英同步，逐条）

| 键 | 改前 | 改后 |
| --- | --- | --- |
| `onboarding.permissions.iphone_app_installed.title` | 我已安装 iPhone App | 我已安装 iOS App |
| `onboarding.control_method.iphone_app.title` | 使用 iPhone App | 使用 iOS App |
| `onboarding.remote_availability.no_remote.detail` | 下一步选择 iPhone App 或微信小程序完成体验。 | 下一步选择 iOS App 或微信小程序完成体验。 |
| `onboarding.apple_companion.connection_detail` | 保持 iPhone App 或 Apple Watch App 打开… | 保持 iOS App 或 Apple Watch App 打开… |
| `onboarding.control_source.apple_companion.title` | iPhone / Apple Watch App | iOS / watchOS App |
| `onboarding.iphone_remote.scan` | 在 iPhone 无线麦 SayAll 中扫描二维码… | 在 iOS 无线麦 SayAll 中扫描二维码… |
| `onboarding.iphone_remote.appstore_qr` | 扫描二维码下载 iPhone 无线麦 SayAll App | 扫描二维码下载 iOS 无线麦 SayAll App |
| `connection.phone.qr_title` | 备用方式：使用 iPhone App 扫码连接 | 备用方式：使用 iOS App 扫码连接 |
| `onboarding.apple_companion.install` | 从 App Store 安装无线麦 SayAll | （删除） |

刻意**没改**的是指设备的那些：「连接 iPhone 或 Apple Watch」「请在已连接的 iPhone 或 Apple Watch 上按一个普通控制键」「iPhone / Apple Watch 已连接」「没有 iPhone 时」。它们说的是连接的是哪台设备，不是 App 的名字。`onboardingCallsTheCompanionAppIOSApp()` 断言两份 strings 里不再出现 `iPhone App` / `iPhone app`。

### 自动化与构建

- `swift build --disable-keychain --disable-sandbox` 公开构建通过。
- `swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests`：90 项通过（本次新增 3 条、改写 1 条）。
- `swift test --disable-keychain --disable-sandbox --filter LocalizationTests`：8 项通过（中英 key 集合一致，本次净删 1 个键）。
- `plutil -lint` 两份 strings 均 OK。

### 离屏渲染证据

`Screenshots/onboarding-installed-checkbox/` 四张图按新实现重渲（浅色未勾选 / 浅色已勾选 / 深色未勾选 / 英文未勾选），SHA-256 与字节数见该目录 `manifest.json` 与上一节的表。连接页去按钮后的形态用同一份构建渲染 `04-remote.png` 逐张核对：标题 → 说明 → 「等待 iPhone 或 Apple Watch」状态卡 → 「等待控制按键」→ 「所选控制方式还没有连接」，不再有安装按钮。

### 生产页面检查

1. iPhone 路径走到连接页，确认左栏标题下直接是等待连接的状态卡，没有「从 App Store 安装」按钮；右栏二维码与 App Store 徽章仍在。
2. 权限页第 4 项标题为「我已安装 iOS App」；右侧是圆圈，勾选前后与上面三项同形（空圆 → 绿色实心勾）。
3. 切英文：该项为「I already installed the iOS app」，控制方式卡片为「iOS App」，连接页副标题为「iOS / watchOS App」。
4. 通读一遍向导，确认没有残留「iPhone App」字样；指设备的「iPhone 或 Apple Watch」应保留。

### 失败判定与边界

- 连接页左栏又出现下载/安装按钮（同一屏两个下载入口），判定失败。
- 权限页第 4 项右侧又变回方框或其他形状，或与上面三项不同尺寸，判定失败。
- 任何页面仍出现「iPhone App」/「the iPhone app」，判定失败。
- 把「iPhone 或 Apple Watch」这类设备指代也改成 iOS，导致用户不知道要拿哪台设备，判定失败。
- 截图只证明静态形态，不能代替真机勾选、真实连接与下载跳转验收。

## 2026-10-23 会员开通弹窗尺寸回归

适用分支：`codex/onboarding-membership-sheet`。本次只修 Onboarding 里「点击开通会员功能」的呈现尺寸，不改会员判定、连接门禁、购买流程和任何文案。

缺陷现象：在完整构建里点击 Onboarding 右栏的「点击开通会员功能」，弹出的窗口只有「关闭」按钮，会员中心和购买入口不可见，用户因此完全无法开通会员。

根因：`.sheet` 里的内容为 `VStack { 关闭按钮; membershipFeature.settingsView() }`，没有给出任何尺寸约束；而会员中心以整页尺寸设计，内部 `GeometryReader` 用 `contentWidth = min(920, max(0, viewportWidth - 48))` 推算内容宽度，再 `.frame(width: contentWidth)`。可用宽度不足 48pt 时内容宽度被算成 0，整个会员中心被压成不可见。

修复：给 `settingsView()` 加 `.frame(minWidth: 900, minHeight: 620)`。宽度上界刻意小于 Onboarding 窗口最小宽度 980（900 + 两侧 20pt padding = 940），否则窗口缩到最小时 sheet 会溢出窗口，把位于最右侧的「关闭」按钮推到窗口之外。

尺寸证据（`NSHostingView.fittingSize` 实测）：修复前 97 × 82，与截图中那个只剩「关闭」按钮的小方块一致；修复后 940 × 696。对照组「`settingsView()` 返回 `EmptyView`」为 90 × 64，与本次实测的 97 × 82 不同，可据此区分「内容被压扁」和「会员模块未初始化」两种原因。

### 自动化与构建

- `swift build --disable-keychain --disable-sandbox` 公开构建通过。
- `swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests`：77 项通过，其中新增 `membershipSheetGivesTheMembershipCenterAnExplicitSize()` 静态断言，防止再次移除尺寸约束。

### 生产页面检查

1. 完整构建走到权限页，右栏出现「点击开通会员功能」，点击后弹窗应为接近 940 × 696 的窗口。
2. 弹窗内能看到会员中心内容：套餐、登录入口和购买按钮，且可滚动，不被裁切。
3. 关闭按钮仍在弹窗右上角，始终可见，且不在滚动区域内；点击后回到 Onboarding 且不丢失当前步骤。
4. 按 Esc 也能关闭弹窗。未设置 `interactiveDismissDisabled`，因此交互式关闭必须保留；如果加入了禁用逻辑，需同步本手册和失败判定。
5. 把 Onboarding 窗口缩到最小宽度（980）后再打开弹窗，关闭按钮仍须完整落在窗口内，不能被推到窗口边缘之外。
6. 在未登录状态点击购买，应弹出登录流程，而不是空白或直接关闭；登录弹窗的 Esc 只关闭登录弹窗，不应连带关闭会员中心。

### 失败判定与边界

- 弹窗仍为小方块、只有「关闭」按钮、会员内容不可见、内容被裁切成细条、点击购买没有任何反应，均判定失败。
- 弹窗打开后无法关闭（关闭按钮不可见、Esc 无效、关闭后卡在空白页），属于阻塞级失败：用户会被困在 Onboarding 里出不来。
- 只验证尺寸约束属于回归防护，不能证明真实购买成功。真实登录、支付和会员开通仍需在正式签名安装包上用真实账号验收；本机无法准备带签名的私有 artifacts，公共构建又不包含会员能力，因此本次未做真实购买验收。

## 2026-10-23 权限页新增「我已安装 iOS App」勾选项

适用分支：`codex/onboarding-membership-sheet`。本次在权限页左栏加一行必选勾选项，不改右栏二维码、会员提示、弹窗，也不改任何权限判定。

位置：权限清单的第 4 项，**在三条系统权限之下**，与权限行同一列、同一 10pt 间距，读起来是清单里多出来的一项，而不是另一块卡片。

同一轮还移除了原来紧跟其后的那张「iPhone 或 Apple Watch 连接将在下一页检查」提示卡（`statusCard(icon: "network", …)`）：它和勾选项的「已确认，下一页会用真实连接验证」说的是同一件事，留着等于同一句话讲两遍。卡片的 6 个文案键（`onboarding.permissions.apple_companion.*`、`onboarding.permissions.web_remote.*`、`onboarding.permissions.mobile_network.*`）一并删除，不留死键；`permissionsPageNoLongerShowsTheNextPageCheckCard()` 反向锁定，防止它长回来。

形态（设计稿方案 C，两态）：

- 未勾选：整块染 `accentColor` 6.5% 并加 1pt `accentColor` 18% 内描边，左侧 32pt 圆底 `iphone` 图标，标题「我已安装 iOS App」14pt semibold，说明「还差这一步：勾选后才能继续」12pt，右侧 19pt 空圆（`circle`，`secondary` 色）——与上面三项权限行同一形态。
- 已勾选：底色褪回与权限行相同的 `primary` 3.5%，去掉描边，图标与右侧园形标记转绿（`#30b350` 量级，`checkmark.circle.fill`），说明改成「已确认，下一页会用真实连接验证」。
- 强调块用的是 App 自己的 `accentColor`，不是设计稿里的系统蓝 `#007aff`：权限行图标本来就用 `accentColor`，固定蓝会和整页冲突。这台机器上的 accent 是珊瑚红，所以截图里偏红。

只在 `onboardingControlMethod == .iPhoneApp` 时显示：实体遥控器和网页遥控路径不装这个 App，出现该行会被误读成第四项系统权限。

勾选前「继续」禁用。判定放在 `OnboardingFlowPolicy.canContinue` 而不是视图里，条件为 `controlMethod != .iPhoneApp || phoneAppInstallConfirmed`；参数默认 `true`，所以 `FirstUseDiagnostics` 这类不关心勾选的调用方行为不变。

勾选状态是 `@State`，不写 `AppSettings`：它确认的是「这台 iPhone 上装过 App」，重进向导重新确认更安全。为离屏截图能拍到第二种状态，`OnboardingView.init` 增加 `initialPhoneAppInstalled`（与 `initialInputMethodGuideStep` 同一套写法），渲染器入口是 `REMOTE_MIC_ONBOARDING_SCREENSHOT_PHONE_APP_INSTALLED=1`。

实现细节：走 `onboardingToggle`（离屏探针读得到值、也能直接置值），配 `.toggleStyle(.button)` + `.buttonStyle(.plain)` 去掉系统 Switch 并让整行可点。右侧状态标记最初是自绘的 20pt 圆角方框（更像「复选框」、也更接近设计稿），但与上面三项的 19pt 圆形并排时会被读成两类不同控件，已改为与 `permissionRow` 完全相同的 `checkmark.circle.fill` / `circle`。

### 自动化与构建

- `swift build --disable-keychain --disable-sandbox` 公开构建通过。
- `swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests`：80 项通过，含本次新增三条：
  - `iphoneAppConfirmationGatesThePermissionsStepOnlyOnTheIPhonePath()`：三项权限全开、只差勾选时 iPhone 路径不能继续；勾选后可以；实体遥控器与网页遥控不受影响；不传参数时保持原行为。
  - `iphoneAppConfirmationRowIsAToggleOnTheIPhonePathOnly()`：托管生产视图后，iPhone 路径注册了 `permission.iphone-app-installed` 开关、初值 false、`invoke` 后变 true；实体遥控器路径没有这个开关；`initialPhoneAppInstalled: true` 能预置已勾选。
  - `permissionsPageNoLongerShowsTheNextPageCheckCard()`：权限段落里不再出现 `statusCard(`，视图与两份 strings 都不再引用被删的 6 个文案键。
- `swift test --disable-keychain --disable-sandbox --filter LocalizationTests`：中英文 key 集合一致（本次新增 3 个键、删除 6 个键，两边同步）。

### 离屏渲染证据

四张图都取自权限页（`03-permissions.png`），用同一份构建产物、同一入口渲染（`_CONTROL_METHOD=iphone_app` + `_CONTROL_SOURCE=apple_companion`），尺寸 2040 × 1600（窗口 frame，内容区 1020 × 772）：

| 文件 | 外观 / 语言 / 状态 | SHA-256 |
| --- | --- | --- |
| [`installed-checkbox-zh-hans-light-pending.png`](../Screenshots/onboarding-installed-checkbox/installed-checkbox-zh-hans-light-pending.png) | 浅色 / 中文 / 未勾选 | `5a4e5a6c3ce66659b519b92a411c0aeb19c26f4f39650b8ec9a078d064863fb6` |
| [`installed-checkbox-zh-hans-light-confirmed.png`](../Screenshots/onboarding-installed-checkbox/installed-checkbox-zh-hans-light-confirmed.png) | 浅色 / 中文 / 已勾选 | `9aa054579cfebda400b01cb8748b3902866bfd43455b1df5d8ac647e534abd16` |
| [`installed-checkbox-zh-hans-dark-pending.png`](../Screenshots/onboarding-installed-checkbox/installed-checkbox-zh-hans-dark-pending.png) | 深色 / 中文 / 未勾选 | `b68d522cf5fd646ec003b29d4a81e2e4faa6a632aeb90e18195338b9c2157494` |
| [`installed-checkbox-en-light-pending.png`](../Screenshots/onboarding-installed-checkbox/installed-checkbox-en-light-pending.png) | 浅色 / 英文 / 未勾选 | `5c33f9e25a9c7085bced3666ef27f364a3e56ae50eca786cabb0e7fad300fae2` |

渲染环境没有蓝牙权限，所以四张图里「继续」都是禁用的，且勾选项下方会出现橙色的「还需要蓝牙权限」运行期提示卡（这不是固定内容，权限开启后消失）；「勾选后解锁继续」由上面的纯函数用例证明，不由截图证明。

### 生产页面检查

1. 完整构建、选择 iPhone 来源进入权限页，确认左栏清单是 4 项，第 4 项在「辅助功能」之下、是清单的最后一项（它下面不应再有「iPhone 或 Apple Watch 连接将在下一页检查」那张卡），与上面三项左边线对齐、间距一致。
2. 未勾选时该行底色明显比其余三行更亮/更染，且有一条细描边；右侧是空圆圈（与上面三项同形），说明文字为「还差这一步：勾选后才能继续」。
3. 点这一行任意位置（图标、标题、空白处都要试），确认整行都能勾选，不是只有右侧圆圈能点。
4. 勾选后确认底色立刻褪回与权限行一致、图标变绿、右侧圆圈变成绿色实心带白勾、说明变成「已确认，下一页会用真实连接验证」；再次点击可取消勾选。
5. 三项权限都开、只差这一项时，确认「继续」是禁用的；勾选后立刻变成可点。
6. 关闭向导重新进入，确认该行回到未勾选——这个状态不该落盘。
7. 切到实体遥控器或网页遥控路径的权限页，确认这一行不出现。
8. 切深色外观，确认未勾选态仍能与其余三行区分（靠底色与描边），勾选后与其余三行一致。

### 失败判定与边界

- 该行出现在三条权限之上、被挤进右栏、与权限行间距不一致或左边线参差，均判定失败。
- 勾选项下面又冒出「iPhone 或 Apple Watch 连接将在下一页检查」那张卡（同一句话说两遍），判定失败。
- 只有右侧圆圈能点、点标题或行内空白没有反应，说明点击目标没覆盖整行，判定失败。
- 右侧标记与上面三项权限行不同形（矩形、方框、白底勾等），判定失败。
- 勾选前后底色没有变化，或勾选后仍然保留强调底色与描边，判定失败。
- 三项权限全开、未勾选时「继续」仍可点，或勾选后仍不可点，判定失败。
- 实体遥控器/网页遥控路径出现该行，或该行出现后拦住这两条路径的「继续」，判定失败。
- 重进向导后仍保持勾选，说明状态被持久化，判定失败。
- 截图只能证明布局、配色与两态切换，不能代替真机勾选、（真实权限齐全时）继续按钮解锁和真实 iPhone 连接验证。

## 2026-10-23 语音测试页核对卡改为按实际手势与工具能力生成

适用分支：`codex/onboarding-membership-sheet`。只改语音测试页（`07-voice-test`）里那张橙色「测试前核对」卡，不改手势判定、不改 `OnboardingFlowPolicy`、不改音频与语音链路的任何行为。

改的是三处会让用户对不上的地方：

1. **标题里的「必须一致」是错的。** 原文「测试前核对：无线麦 SayAll 与%@必须一致」。遥控器只能按住、语音工具只能按一下时（Siri Remote / 小米遥控器 + Typeless），两侧手势本来就不一致，靠 `fnTapModeEnabled` 把长按换算成一次点按。这句话直接把正确配置说成了错误配置。现在标题只说明「在这一步核对」，不再断言两边相同。
2. **第一条勾选是泛称。** 原文「我已确认语音工具使用上方显示的操作方式」，用户不知道要去工具里改哪个开关。现在按 `resolvedVoiceGestureMode`（配对计划 → 用户偏好 → 工具推荐值 → 按住）出两条文案之一，和上方的语音键提示条同源。
3. **全局唤起被当成所有工具的共性。** 原文勾选写死「豆包已开启“全局唤起语音”」，失败提示也无条件说「全局唤起」。实际上只有豆包有这一项：微信输入法、Typeless、Vokie 没有，`.other` 未观察过。现在由 `VoiceToolAdapterProfile.globalActivationSupport`（`true` / `false` / `nil`）决定勾选是否出现、失败提示走哪条键，文案里的工具名走运行时插值。

另外三处收尾：

- 行标签「无线麦 SayAll 音频输出」是写死的，值却是运行时设备名，旧驱动用户会看到「标签写 SayAll、值写 MiRemoteV 2ch」。标签改成「音频输出设备」，设备名只从 `selectedAudioDevice?.name` 出。
- 音频输出那一行移到核对卡外面：它讲的是这一侧把声音送到哪个设备，语音工具并不知道这行，挂在「在 X 里核对」的标题下会被读错归属（详见下面的「归属修正」）。
- 设备名、工具名在勾选里全部走运行时参数，不再出现第二处写死的名字。

死键处理（Sources 里 0 引用，逐条 `git grep` 确认）：删除 `onboarding.voice_test.configuration.binding_expected`、`onboarding.voice_test.microphone_confirmation.title`、`onboarding.voice_test.other_detail`、`onboarding.voice_test.configuration.voice_gesture_checkbox`（被两条按手势分流的键取代）。`microphone_confirmation.detail` 曾短暂复活，后按下面的「归属修正」一并删除。

版式：核对卡外层间距 4 → 8、内边距 8 → 10、勾选包成 6pt 一组；语音测试页外层间距 8 → 12。

### 文案二次压缩（同日）

第一版说明写的是「上一步已经讲过怎么设置。下面三条都勾上，才能开始测试。」，麦克风小字写的是「选“SayAll”只是把遥控器声音送进系统，不会改动豆包输入法自己的麦克风设置，所以要在它里面再选一次“SayAll”。」两句都太长，而且第一句带出两个错：

- **「三条」是错的。** 只有豆包有「全局唤起语音」那条勾选，微信输入法 / Typeless / Vokie 实际只有两条。标题「核对这三项」同样写死了三。现在标题改成「测试前在 %@ 里核对这几项」、说明改成「都勾上才能开始测试。」，**不再出现任何计数**，勾选条数由能力字段决定。
- **「上一步已经讲过怎么设置」没有信息量。** 用户刚从上一步过来，这句只是交代向导自己的结构，删掉。

麦克风小字压成一行「这里只决定遥控器声音往哪送，%@的麦克风要单独选一次。」：保留「这里是声音往哪送、不是工具用哪个麦克风」这个唯一有用的信息，去掉重复两次的设备名（勾选那一行刚说过）和「在它里面」这种模糊指代。参数个数从 3 个减到 1 个。

压缩的副作用是好的：Typeless 未运行的异常态原先会多出两行红色运行时状态加一行桥接说明，把增益卡顶出 1020 × 772 的首屏；文字收紧后，异常态也完整放下了，`manifest.json` 里原先那条「需要滚动」的说明已随之删除。

### 归属修正：音频输出行离开核对卡，麦克风小字删除（同日）

两条都是「这句话不该在这里」的问题：

- **「音频输出设备 ✓ SayAll」不属于核对卡。** 它上面就是「测试前在豆包输入法里核对这几项」，读起来像要去豆包输入法里核对一个叫「音频输出设备」的选项——但这一行讲的是我们这一侧把声音送到哪个设备，语音工具根本看不到它。现在它移到核对卡外、卡的上方，用喇叭图标 + 灰色标签单独成行，作为「先确认声音从哪出去」的前置状态；就绪绿勾、未就绪红叉（另一张 bridged 截图正好是红叉态）。
- **麦克风小字删除。** 「这里只决定遥控器声音往哪送，%@的麦克风要单独选一次。」解释的是机制，而上面那条勾选本身已经是行动指令（「我已确认%@的麦克风是“%@”」），再解释一遍只是重复。机制说明属于上一步的图文引导（`onboarding.voice_tool.guide.screenshot.doubao_settings` 已经写了「在麦克风选择中选择…」）。因此 `onboarding.voice_test.microphone_confirmation.detail` 连同渲染点一起删除，不留死键。

核对卡现在只剩三样东西：标题、一句说明、勾选。卡外的音频状态行与卡内勾选在版式上靠「有无背景」区分，不再靠间距猜测归属。

### 自动化与构建

- `swift build --disable-keychain --disable-sandbox` 公开构建通过。
- `swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests`：87 项通过，含本次新增七条：
  - `globalVoiceSupportIsUnknownForToolsWeNeverObserved()`：豆包 `true`，微信 / Typeless / Vokie `false`，其他与未选择为 `nil`。
  - `holdOnlyRemoteAndToggleOnlyToolBridgeThroughFunctionTap()`：Typeless + Siri Remote 解析成按一下并开启 `fnTapModeEnabled`；豆包 + Siri Remote 仍是按住、不开换算。
  - `voiceTestGestureCheckboxFollowsTheResolvedGesture()`：勾选项走 `resolvedVoiceGestureMode`，两条键都在，旧键不再被引用，桥接提示条件存在。
  - `voiceTestFailureHintOnlyMentionsGlobalActivationWhenTheToolHasIt()`：失败提示分两条键，中文里那句写死「全局唤起」的旧文案已不存在。
  - `voiceTestDropsKeysNoViewEverRendered()`：四个死键在两份 strings 里都已删除（含后来删掉的 `microphone_confirmation.detail`）。
  - `voiceTestConfigurationCopyDoesNotPromiseAFixedNumberOfChecks()`：标题与说明里不出现固定计数（只查这两个键，「三项权限」这类准确描述不受影响）。
  - `audioOutputStatusSitsOutsideTheToolChecklistCard()`：核对卡段落里不再出现 `sayall_audio_output` / `configurationStatusRow`，且音频行必须在卡之前渲染。
- `swift test --disable-keychain --disable-sandbox --filter LocalizationTests`：8 项通过，中英文 key 集合与占位符个数一致。

### 离屏渲染证据

三张图都取自语音测试页（`07-voice-test.png`），用同一份构建产物、同一入口渲染，尺寸 2040 × 1600（窗口 frame，内容区 1020 × 772）：

| 文件 | 组合 / 状态 | SHA-256 |
| --- | --- | --- |
| [`voice-test-zh-hans-light-hold.png`](../Screenshots/onboarding-voice-test-consistency/voice-test-zh-hans-light-hold.png) | 中文 / 豆包 / 按住 | `2e20b511d340dd47a1ce41b8988c9a3c8b738a7802d65895483dae59073f365b` |
| [`voice-test-zh-hans-light-bridged.png`](../Screenshots/onboarding-voice-test-consistency/voice-test-zh-hans-light-bridged.png) | 中文 / Typeless + 小米遥控器 / 按一下 + 桥接说明 | `b960bf5361aa0db83ad6a3def0fd64c44066a86bfa9627bdbd75ec3b3d8a9ffe` |
| [`voice-test-en-light-hold.png`](../Screenshots/onboarding-voice-test-consistency/voice-test-en-light-hold.png) | 英文 / 豆包 / 按住 | `33abdd7e19502e2c00cdfb221865358be3734a235a6515ba563ba333307931d1` |

旧驱动设备名（`MiRemoteV 2ch`）未单独出图：设 `REMOTE_MIC_ONBOARDING_SCREENSHOT_AUDIO_NAME=legacy` 可复现，核对卡上方的音频行与第三条勾选会一起显示真实设备名。

渲染环境没有真实的语音工具进程，勾选都是未勾选态；「全部勾选才允许继续」的逻辑由 `OnboardingFlowPolicy` 的既有用例覆盖，不由截图证明。

### 生产页面检查

1. 用豆包进入语音测试页，确认标题是「测试前在豆包输入法里核对这几项」、说明是「都勾上才能开始测试。」，不再出现「必须一致」，也不再出现「三条」「三项」这类计数。
2. 确认「音频输出设备」这一行在橙卡**外面**、卡的上方，右侧是系统里真实的设备名（新装 `SayAll`，旧驱动 `MiRemoteV 2ch`）；这一行不该出现在橙卡的勾选清单里。
3. 确认第一条勾选写的是「我已把豆包输入法设为“按住说话”」，与上方语音键提示条一致。
4. 换 Typeless 并把控制方式设为实体遥控器：确认上方提示条变成「按一下语音键开始说话，再按一下结束」，第一条勾选同步变成「按一下开始，再按一下结束」，且下方多出一行带双向箭头的小字解释长按换算。
5. 换成微信输入法 / Typeless / Vokie / 其他：确认没有「全局唤起语音」那条勾选（只剩两条），而标题和说明里的措辞不变、仍然读得通——这是「不写数量」的意义。
6. 用豆包：确认第二条勾选是「我已确认豆包输入法开启了“全局唤起语音”」，点开豆包确实有这个开关。
7. 确认麦克风勾选下方**没有**小字说明；橙卡里除标题、说明、勾选之外不应再有其他文字。
8. 拨掉语音工具进程让它报「尚未运行」，再让某次测试收不到文字，确认红色失败提示里：豆包说「全局唤起语音」，其余工具说的是「正在运行并已开启语音输入」，不提全局唤起。
9. 中英文在 1020 × 772 下逐条检查，增益滑杆和数值、底部「继续」都完整可见。

### 失败判定与边界

- 标题或说明里再次出现「必须一致」「与页面提示一致」这类无指向或错误的断言，判定失败。
- 勾选项文案与上方语音键提示条说的不是同一个动作（提示条说按一下、勾选让你确认按住），判定失败。
- 只能按住的控制方式配只支持按一下的工具时，页面没有解释换算，用户会以为自己设错了；缺这行小字判定失败。
- 「音频输出设备」又回到橙卡里、被「在 X 里核对」的标题统辖，判定失败——它会让用户去语音工具里找一个并不存在的「音频输出设备」。
- 麦克风勾选下方又出现解释性小字，判定失败：勾选本身已是行动指令，机制说明属于上一步。
- 无全局唤起的工具上出现「全局唤起语音」勾选，或失败提示让它去找这个开关，判定失败。
- 标签写 `SayAll`、值是 `MiRemoteV 2ch`（或反过来），判定失败。
- 标题或说明里出现「三条」「三项」这类固定数量，导致只有两条勾选的工具上读起来对不上，判定失败。
- 麦克风小字再次出现重复的设备名（勾选那一行已经说过）或「在它里面」这类无指向的指代，判定失败。
- 截图只能证明文案、布局与条件分支，不能代替真机上的语音文字上屏、第三方工具设置核对和跨工具真实链路。



适用分支：`codex/onboarding-appstore-qr`。本次把 iPhone 连接页右栏的占位内容替换为随包交付的 App Store 下载二维码，二维码下方加入 Apple 官方 App Store 徽章，并补充对应中英文说明文案；不改动流程、能力门禁、权限、连接、音频、持久化和左栏 App Store 入口。

变更分类：局部截图渲染与文案变化，不改变用户旅程和门禁判定，因此按定向验证执行，覆盖受影响来源、语言和外观，并做构建与生产清单一致性检查。

二维码静区为约 2 个模块（生成画布 440 × 440，模块整数倍缩放，余量平分到四周）。不要把静区调回 10 个模块以上：过大的白边会让 220pt 显示尺寸下的二维码明显缩小，这也是本次修复的原始问题。

### 自动化与构建

- `swift build --disable-keychain --disable-sandbox` 公开构建通过。
- `swift test --disable-keychain --disable-sandbox --filter OnboardingFlowTests`：76 项通过。
- `swift test --disable-keychain --disable-sandbox --filter LocalizationTests`：8 项通过，中英文 key 集合一致。
- 生产清单一致性：`scripts/build-app.sh` 以 `ditto` 整目录拷贝 `Resources/Onboarding`，`scripts/verify-app.sh` 逐个校验该目录下的 PNG 出现在 App bundle 中；本次新增 6 张 PNG 无需修改打包脚本。

### 生产页面检查

1. 公开构建选择 iPhone 来源，进入连接页，确认右栏显示 App Store 下载二维码，白色衬底完整，图片不被裁切或拉伸。
2. 确认二维码四周白边紧凑：二维码图案与白色卡片边缘的距离应明显小于二维码宽度的十分之一，不能出现大片空白把二维码挤小。
3. 确认二维码下方显示 Apple 官方 App Store 徽章：中文界面为 black 变体的“App Store 下载”，英文界面为 black 变体的“Download on the App Store”，徽章比例不变形、描边和圆角完整、未被裁切或重新着色。
4. 中文确认说明文案为“扫描二维码下载 iPhone 无线麦 SayAll App”，英文确认为“Scan this code to download SayAll for iPhone”。
5. 用二维码扫描工具核对内容：中文指向 `https://apps.apple.com/app/%E6%97%A0%E7%BA%BF%E9%BA%A6/id6797208067`，英文指向 `https://apps.apple.com/app/sayall/id6797208067`，与左栏“从 App Store 安装”入口指向同一链接。
6. 切换浅色和深色外观，确认深色下二维码仍有白色衬底，徽章切换为 white 变体且文字可辨认，中文字号不小于 12pt，右栏内容整体居中不贴顶。
7. 完整构建进入同一页面，确认右栏仍优先显示当前监听周期的动态配对二维码，静态下载二维码只作为无动态邀请码时的降级显示。

### 失败判定与边界

- 右栏空白、没有二维码、显示成 iPhone 插画、二维码内容与语言不匹配、中文界面出现英文二维码或反之、深色下二维码缺少白色衬底且无法识别，均判定失败。
- 二维码四周仍是大片白边、徽章缺失或显示成自绘图标、徽章被拉伸变形/改色/加边框、浅色外观用了 white 变体或深色外观用了 black 变体导致看不清，均判定失败。
- 徽章必须使用 Apple 官方 Marketing 资源原样缩放，不得自行重绘或替换为 SF Symbols。
- 离屏截图和二维码解码只能证明静态界面与链接内容，不能代替真实 App Store 跳转、真实 iPhone 安装与真实扫码连接验收。

### 截图证据

离屏入口：`REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR`、`REMOTE_MIC_ONBOARDING_SCREENSHOT_LANGUAGE=zh-Hans|en`、`REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE=light|dark`、`REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_SOURCE=apple_companion`，来源为 `Sources/RemoteMic/OnboardingScreenshotRenderer.swift` 的生产 `OnboardingView`。受影响的 `04-remote.png` 记录如下（PNG，2040 × 1600，Retina 2x）。四张截图已随本次改动提交到 `Screenshots/onboarding-appstore-qr/`，并附 `manifest.json` 记录源文件与截图指纹：

| 语言 | 外观 | 文件 | SHA-256 |
| --- | --- | --- | --- |
| zh-Hans | light | `04-remote.png` | `3e61e9388e9bfaa7f9275d8bf299e4b005eb0273902d5a6570192933fa8e86c4` |
| zh-Hans | dark | `04-remote.png` | `18aecf812c3b161e3f03c9e786b1570b0943922e2534c5e27183781c766955bf` |
| en | light | `04-remote.png` | `9b5e8721353811d95148d46b51956999504b3a8e7c722a2cfceb945103e5a1ac` |
| en | dark | `04-remote.png` | `584d5e5fe1ea4704f504670b17307ae251ce99133830587241a125157eeaeeba` |

随包交付的静态素材（均位于 `Resources/Onboarding/`，PNG）：

| 文件 | 尺寸 | SHA-256 |
| --- | --- | --- |
| `appstore-download-qr-zh-hans.png` | 440 × 440 | `f6025aaa0dfdf11f6cec71bde66a35ed90e5ac88298bfc7427c724939667e385` |
| `appstore-download-qr-en.png` | 440 × 440 | `f59e0c08e1911a5652fac973a757409cd4ce5157046f0ae43845a83df04aab80` |
| `appstore-badge-zh-hans-light.png` | 480 × 176 | `e71fe977f1565c66e4bf2fa137116a2052fe1ebcfe12ac5d13a030746604002e` |
| `appstore-badge-zh-hans-dark.png` | 480 × 176 | `43213832f6f731cec3afb9bb433d81aa8d70b7e25942ee5d4f4e0d89809ad812` |
| `appstore-badge-en-light.png` | 480 × 160 | `254e8909c0213b29961e775925f0829fe5b736dca4be41edd419e110ba9d9d16` |
| `appstore-badge-en-dark.png` | 480 × 160 | `07193fd96b36ffdf46bc1cc008146f731b10747f1f8835a23c56aca50851cd00` |

二维码由 CoreImage `qrCodeGenerator`（`correctionLevel M`）生成后用 `CIDetector` 回验内容；徽章取自 Apple Marketing Tools 官方 badge 服务（`tools.applemediaservices.com/api/badges/download-on-the-app-store/<black|white>/<en-us|zh-cn>`），SVG 原样栅格化为 480px 宽，不改色、不改比例。

## 2026-10-19 无屏配置应用定位回归

适用分支：`codex/fix-agent-app-location`。本次只修改欢迎页复制的终端命令。页面、权限、连接、语音与持久化实现没有变化。

1. 准备标准安装目录中的 SayAll，同时保留标准目录外的旧测试副本。
2. 分别检查中文和英文复制内容。命令只检查系统和当前用户的 Applications 目录，不调用 Spotlight。
3. 运行 `swift test --disable-keychain --filter OnboardingFlowTests`。应用定位用例执行复制内容中的 shell，模拟文件可执行状态，不启动 App、不修改配置。
4. 核对选择顺序：系统 SayAll.app、系统无线麦SayAll.app、当前用户 SayAll.app、当前用户无线麦SayAll.app。不可执行的候选必须被跳过。
5. 标准目录没有可执行候选时，命令必须退出 1，并返回 status=not_found、reason=installed_app。Agent 应确认安装位置，不得改用测试副本或下载归档。
6. 现场配置时，确认执行的是安装副本。继续核对 `--agent-configure --verify --json`，并完成真实权限、按键、音频和文字上屏；不得把 configured 当作真实语音通过。

失败判定：选择标准目录外的副本、忽略可执行性、两种语言行为不同、缺失安装时仍尝试启动，或把配置准备报告为真实验证完成。

验证结果和边界：旧命令在新增回归用例中失败；修复后的测试、构建及本机只读定位结果见 [Bug 记录](../Bugs/2026-10-19-agent-app-location.html)。复制命令不受界面语言以外的外观状态影响；本次不改生产页面清单或渲染。自动化不替代真实语音验收，也不证明运行中的 App 已重新加载配置。

## 2026-10-17 Onboarding 布局与来源显示回归

适用范围：右栏布局、控制来源选择页和微信小程序连接页。该变更属于流程共享布局与用户可见文案变化，必须执行离屏生产截图、自动化测试和真实窗口检查。

### 自动化检查

- 使用 `swift test --disable-keychain --filter OnboardingFlowTests`。
- 确认来源可见性策略隐藏 Chromecast，但保留其他来源和运行时枚举。
- 确认右栏使用可用高度居中布局，左栏滚动使用隐藏指示器。
- 确认中文显示“下一步生成二维码”，英文显示“Next, generate a QR code”。

### 生产页面检查

1. 在 `1020 × 772` 窗口打开控制来源页。
2. 展开“更多控制方式”，确认内容可以滚动访问，页面不显示滚动条或滚动轨道。
3. 确认列表中没有 Chromecast 卡片；确认小米、已安装的 Siri Remote、iPhone 和微信小程序来源仍按当前构建能力显示。
4. 进入欢迎页、权限页、连接页和完成页，确认右栏主图、说明和状态卡在可用高度内整体居中。内容较高时可以滚动，初始位置不能贴在顶部。
5. 进入“允许无线麦连接和控制 Mac”页，在二维码尚未生成状态确认右侧文案为“下一步生成二维码”；英文确认文案为“Next, generate a QR code”。
6. 切换浅色和深色外观，并重复第 2 至第 5 步。中文字号不得小于 12pt，右栏不得裁切。

### 失败判定与边界

- 出现 Chromecast 卡片、滚动条、右栏内容贴顶或旧二维码文案，均判定失败。
- 自动化测试和离屏截图只能证明页面结构、可见性和文案。真实微信扫码、真实控制设备连接和系统权限仍需现场验证。

## 2026-10-16 会员与安装状态回归

适用分支：`codex/onboarding-membership-siri-audio-20261015`。本次包含来源门禁和持久化变化，按流程类验证；纯截图与单元测试不能替代真实旅程。

- 准备：保留原音频选择与 Siri Remote 开关；分别使用不含 Siri Package 的公开构建、包含 Package 且有/无 Installer 收据的构建。
- 无收据：欢迎后不显示两代苹果遥控器。旧流程保存 Siri 来源时恢复到选择页，不临时开启服务。
- 有收据：两代入口可选；会员、非会员和有效离线租约均需完成相同的真实连接、PCM、正常结束、文字上屏和普通按键门禁。
- 临时启用：进入前关闭，选择后开启；退出后续接、切换来源、返回和重试都不改写进入前快照。非会员完成后关闭；私有组件返回已授权时保留开启。完成动作不得中断活动语音。
- 原已启用：重跑向导，三种会员状态均保留原开关。未选择苹果遥控器时不得新增启用。
- 音频：分别枚举 SayAll、MiRemoteV 2ch 和 BlackHole 2ch，核对选择行、已选状态、工具核对卡和重新进入后的 UID。新旧 SayAll 使用原稳定 UID；同名物理设备不能通过。不重装驱动，不覆盖旧选择。
- 页面：对当前构建全部来源生成中英文、浅色/深色完整九页；另覆盖 PKG 缺失、旧设备名、会员试用完成提示。按下方生产清单逐张检查 `1020 × 772` 内容尺寸和窗口 chrome，记录 PNG 尺寸及 SHA-256。
- 现场：分别执行首次进入、退出续接、关于页重跑、真实 Siri 语音、极速按下/释放、连续会话、异常恢复和完成后设置开关检查。记录首字耗时、尾音完整及 `interrupted_samples=0`；RC003 稳定语音基线仍需回归。

本轮自动化结果：公开仓库 `swift test --disable-keychain --disable-sandbox` 通过 885 项、68 个 suite；包含 Siri Package 的定向 Onboarding、Localization 和音频设备测试通过 97 项、8 个 suite。`git diff --check` 与仓库治理检查通过。Release `SayAll.app` 已通过 `scripts/verify-app.sh` 和 `codesign --verify --deep --strict`。

本轮离屏结果：生产隐藏入口生成 108 张基础 PNG（小米来源、Siri 第 6/7 代、中文/英文、浅色/深色），另生成 PKG 缺失旧设备名和 Siri 临时试用状态 72 张。每张为 2040 × 1600 PNG。证据目录为 `/Users/andy/.codex/worktrees/03ed/onboarding-evidence-20261016`，清单为 `manifest.sha256.json`。已逐张检查窗口 chrome、标题、导航、状态卡、右栏、裁切、对比度和中文字号。静态截图不证明真实权限、蓝牙、音频、Siri Remote 或第三方文字上屏。
- 日志：检查 `ONBOARDING SIRI_REMOTE` 的 availability、started、temporarily_enabled、completed，以及停用的 `membership_required` 或保留原因；不含收据正文、设备身份或用户文字。

失败判定：无收据仍有入口、非会员绕过真实语音门禁、完成后遗漏临时开关清理、关闭老用户开关、覆盖音频选择、提前截断语音或状态日志与实际结果不一致。

自动化与截图结果在本次 PR 中记录。真实 Installer、权限、蓝牙、音频、第三方文字及候选包旅程尚待实机验收；不沿用历史验收结论。

## 适用范围

会员连接授权：Phone/Web 入口在未登录、非会员或授权过期时显示私有组件提供的会员按钮，不展示可用连接码。登录有效 Plus 后才进入原配对、批准和连接流程。会员弹窗关闭后返回向导。验证退出、租约过期和切换服务环境时旧入口失效，详见 [CompanionMembership](CompanionMembership.md)。必须覆盖完整生产流程截图及中英/明暗；当前拆分 PR 的自动化通过，完整截图和真机验收仍待补充，不能由 QR 静态截图代替。

- 版本：当前待验证的无线麦SayAll.app 控制设备前置选择与 Fn 统一 Onboarding
- 来源：当前 PR 或已合入 `main` 的精确 Commit；发布流程不使用候选分支作为普通发布入口
- 平台：macOS 14 及以上
- 功能状态：本手册定义当前 Onboarding 的完整回归要求；具体 Commit 已完成和未完成的自动化、截图、双架构 CI、正式签名、系统设置、真实遥控器、Nearby、网页版及第三方语音工具验收，必须在对应 PR 中按实际结果填写，不能沿用本文中的历史候选结论。
- 目标：确认只有真正全新安装需要完整设置向导；欢迎后先选择当前构建实际支持的控制设备，再按固定顺序选择输入工具；Onboarding 临时固定 Fn，只有真实连接、按键、语音和文字上屏通过后才持久化。

> 历史候选状态：Onboarding Fn-only 按键策略曾在候选分支完成本地流程自动化、58 张浅色/深色生产截图、设置页浅深色截图和 Release 构建；当时仍待双架构 CI、正式签名改名权限连续性、系统设置真实跳转、实体遥控器、iPhone Nearby、手机 Safari 网页版及第三方语音工具现场验收。该记录不能替代当前 Commit 的验证结果。

> `1.9.18 (171)` 可靠性候选修复权限页返回后被已连接遥控器立即自动送回的问题，并将语音测试的文字目标改为可验证的 AppKit first responder；诊断按单次语音 attempt 记录一个终态和脱敏时延。

> `v1.8.14 (106)` 候选在原流程上增加单一主要修复动作、脱敏设置诊断、失败码与阶段耗时记录，以及完成页定向回跳；新增用例见 [`FirstUseSuccess.md`](FirstUseSuccess.md)。

> 本手册中带具体版本、日期或旧分支名称的段落是历史复现与验证证据，不覆盖顶部适用范围、跨平台产品规范和当前 PR 的真实验证结果。

## 正式 iOS 与小程序连接入口

本次分类为连接流程与能力变化。完整旅程门禁保留。

1. 选择 iPhone，检查安装入口打开正式 App Store。中英文链接分别对应无线麦和 SayAll，不再使用 TestFlight。
2. 选择微信小程序 SayAll，使用微信扫描动态小程序码。打开后自动连接，无数字验证码和 Mac 批准；本页不提供浏览器或固定码。
3. 断网、取码超时、图片无效与码过期时，检查失败提示和重试。返回、关闭、退出续接、切换来源和服务环境时，旧码不得恢复旧连接。
4. 连接状态仍由真实生产会话决定；普通按键、完整音频和第三方文字上屏门禁保持不变。其他来源在线不能代替小程序完成检查。
5. 生成当前启用来源的完整生产流程截图。分别检查中英文、浅色和深色。截图只证明界面，不能代替微信、权限、音频或文字实测。

自动化、构建、截图、部署和真实验收分别在 PR 记录。未执行的真实旅程必须标为待验证。

## 虚拟麦克风名称回归

本次分支为 `codex/sayall-audio-name-20261003`。名称专项步骤见 [VirtualMicrophoneNaming.md](VirtualMicrophoneNaming.md)。

1. 新安装选择 SayAll。页面、语音配置摘要及第三方麦克风期望值必须显示 SayAll。
2. 旧安装选择 MiRemoteV 2ch。上述位置必须继续显示旧名，不得仅替换界面文字。
3. 升级后检查音频选择、完成状态和按键映射。保存值不得改变；已完成用户不得被强制重跑。
4. 从关于页重跑，检查返回、退出续接、缺失设备阻断、取消恢复、真实语音文字门禁和完成后进入设置。
5. 对两种名称分别覆盖小米、iPhone 和网页来源。公开构建不含手机或网页实现时，使用版本清单固定的私有 Package；不得把缺失来源的截图当作完整覆盖。
6. 生成生产隐藏入口的中英文浅深完整流程截图，并补充旧名称状态。按当前页面清单覆盖；历史 58 张清单不能替代当前流程。逐图检查标题、导航、右栏、状态卡、裁切、对比度和中文字号。
7. 名称变化不降低真实音频和文字验收门槛。Fn 极速按下/释放、连续会话及异常恢复仍须实机执行。

自动化、截图、构建和实机结果分别记录；未执行的实机项目保持待验证。

## 测试前准备

1. 分别准备新安装 SayAll 和旧安装 MiRemoteV 2ch 的测试 Mac，并保留 BlackHole 2ch；保留蓝牙扬声器或其他普通输出设备，用于确认只有这些受支持虚拟设备可以通过向导。另按构建能力准备 RC003、苹果遥控器第 6 / 7 代、Chromecast 语音遥控器、iPhone、Apple Watch、可用 Safari 的手机，以及豆包、微信、Typeless、Vokie 和至少一个其他语音工具。
2. 退出其他 Remote Mic 实例，备份需要保留的个性化设置。
3. 使用独立测试账号或清除本 App 的 Onboarding 测试键，确保进入全新流程；不要删除用户正式配置。
4. 打开 `~/Library/Logs/RemoteMic/runtime.log`，记录每个失败用例的大致时间。
5. 窗口保持 `1020 × 772`，分别使用中文和英文执行布局检查。

## 苹果遥控器主动启用与授权恢复

- 全新配置或旧设备档案均不自动启用苹果遥控器。
- 启动、设备发现和回到前台不得弹出 Siri 授权窗口。
- 在控制来源页主动选择苹果遥控器后，才允许请求安装和首次音频授权。
- 取消后保存等待状态。退出再启动不得自动准备音频或新增窗口。
- 点击重新连接或语音失败恢复后可以再次请求。
- 在遥控器卡片内点击停用后，Siri 音频和 HID 服务停止。重新启用不得接受旧进程的迟到回调。
- 未启用的苹果遥控器卡片显示启用按钮；取消授权后显示重试按钮。
- 卡片不增加说明文字。遥控器图上方不得添加任何元素。
- 遥控器卡片最多三行，右侧不显示对勾；启用按钮位于右侧并垂直居中。
- 上述操作不能直接满足连接、真实音频或文字上屏门禁。
- 普通小米、手机和网页分支不得因此启用 Siri 服务。
- 自动化、截图、构建和真实系统授权分别记录；本轮实机验收仍未完成。

## 逐控件回归矩阵

流程自动化必须分为两层：进程内离屏交互和真实环境验收。进程内层复用生产 `OnboardingView`，在屏幕外的 `NSWindow` 中加载页面，并通过仅供测试注入的 action probe 驱动生产 `Button`、`Link`、`Toggle` action，检查状态更新和导航断言；它不使用屏幕坐标、`CGEvent` 或外部辅助功能点击，因此锁屏、屏幕熄灭或当前用户未登录都不应阻止这层测试。`真实环境` 仍记录需要权限、遥控器、手机或第三方工具的结果；它不能用离屏测试替代。

当前 PR 的 `OnboardingFlowTests.offscreenOnboardingRegistersAndDrivesEveryInteractiveControl` 逐页覆盖生产 Onboarding 中的所有可点击控件：欢迎、AI 配置提示复制、返回/继续、实体设备、更多控制方式展开、备用来源、按住/按一次、五个输入工具、权限行、音频设备、语音测试确认、重新打开、失败恢复、诊断复制和完成动作。系统设置、真实硬件、第三方 App 启动结果和真实文字上屏仍按下表进入现场层。

如果外部 UI 自动化工具报告“Mac 已锁定”或无法取得辅助功能权限，只能将其记录为该自动化通道不可用，不能把“解锁 Mac”列为 Onboarding 的产品前置条件，也不能因此修改用户流程。需要屏幕级坐标、系统权限弹窗、真实蓝牙/音频或第三方 App 文字上屏的用例，单独安排在已登录的现场验收中。

下表的“本机 UI”是控件覆盖清单，不表示必须让用户解锁后才能执行；能由进程内离屏 harness 驱动的控件应归入自动化结果，只有系统弹窗、外部 App、真实硬件和真实文字上屏才进入现场验收。

| 页面 | 可点击控件 | 点击后必须观察到 | 自动化边界 | 本机 UI | 真实环境 |
| --- | --- | --- | --- | --- | --- |
| 欢迎 | 返回（首屏不显示）、开始设置 | 进入控制设备页；无旁路 | 导航顺序、持久化 | 需点击 | 无 |
| 控制来源 | 小米、苹果第 6/7 代卡片 | 只显示当前 Package 支持的实体设备；卡片左侧和右栏使用真图 | Package 过滤、资源解析 | 需逐项点击 | 连接需真机 |
| 控制来源 | 更多控制方式、Chromecast、iPhone/Watch、网页版 | 默认折叠；展开后才能选择当前构建支持的备用方式 | 折叠状态、Package 过滤 | 需逐项点击 | 连接需真机 |
| 控制来源 | 按住说话、按一次说话 | 只选择模式；不提前启动语音 | 支持模式门禁 | 需逐项点击 | 各硬件需真机 |
| 输入工具 | 豆包、微信、Vokie、Typeless、其他卡片 | 豆包、Vokie、其他始终显示；微信与 Typeless 仅在已安装时显示；选择只更新选中态且不打开系统设置 | 安装过滤、选择副作用、排序、Fn staged Binding | 对当前可见项逐项点击 | 安装状态需真机 |
| 输入工具 | 安装豆包 | 仅在明确点击后打开官方入口 | URL 门禁 | 需点击 | 浏览器需真机 |
| 输入工具 | 右栏步骤 1/2/3/4、Vokie 官网 | 每个工具均显示匹配步骤；Vokie 打开官方页面，浅色/深色使用对应截图 | 步骤路由、资源解析、URL 门禁 | 需逐项点击 | 第三方设置需真机 |
| 权限 | 蓝牙、输入监控、辅助功能三整行 | 打开正确系统设置；授权后回到本页刷新 | 权限门禁 | 需点击 | TCC 状态需真机 |
| 连接 | 打开蓝牙设置、重新连接、重新检测按键 | 打开对应入口或重新启动当前来源；实体遥控器、iPhone/Watch、网页版分别显示对应恢复说明，不因点击直接通过 | 恢复去重、来源映射 | 需点击 | 遥控器需真机 |
| iPhone | 安装或打开 iOS App | 打开公开安装入口；连接状态仍由真实会话决定 | URL/连接门禁 | 需点击 | iPhone/Watch 需真机 |
| 网页 | 重新生成二维码 | 生成新二维码并保持当前页面 | WSS 状态机 | 需点击 | 手机浏览器需真机 |
| 音频 | 每个 MiRemoteV 2ch/BlackHole 2ch 行 | 选中设备并刷新输出状态 | 支持设备过滤 | 需逐项点击 | 音频设备需真机 |
| 音频 | 重新检查、安装指南 | 刷新设备列表或打开公开指南 | 恢复动作 | 需点击 | 驱动状态需真机 |
| 语音测试 | 输入框、增益滑块、重新测试 | 输入框保持焦点；增益说明可理解；0–24 dB 调整立即作用于下一次语音；新会话清理旧草稿 | first responder、手动输入拒绝、增益持久化与 PCM 放大 | 需点击 | 真实语音需真机 |
| 语音测试 | 重新打开（Vokie/Typeless 未运行） | 尝试拉起工具；拉起失败仍阻止继续 | runtime gate | 需点击 | 工具运行状态需真机 |
| 语音测试 | 三个确认复选框 | 每项独立切换；未确认不能继续 | 组合门禁 | 需逐项点击 | 第三方设置需真机 |
| 失败恢复 | 当前失败项的恢复按钮、复制诊断 | 执行对应恢复动作；复制内容不含用户文字 | 失败码映射、日志 | 需逐项点击 | 依赖失败条件 |
| 普通按键 | 三个不同普通按键 | 去重计数；完成后继续可用 | 按键计数逻辑 | 需点击 | 遥控器/手机需真机 |
| 完成 | 打开无线麦 | 关闭向导进入主设置页；设置保留 | 完成版本持久化 | 需点击 | 真实流程需真机 |
| 所有页面 | 返回、继续 | 返回只回退一步；继续只在真实门禁满足时可用 | 导航和门禁 | 需逐页点击 | 完整旅程需真机 |

页面上不得展示测试矩阵中的“自动化边界”“本机 UI”“真实环境”等栏目；这些内容只存在于本手册和 PR 验证记录中。

普通用户页面不得展示原始 HID/监听器状态、`Radio`、待验证、未完成、不确定等研发术语。辅助功能说明不得绑定 Typeless 或任一特定输入工具；Apple 设备连接状态必须同时覆盖 iPhone 和 Apple Watch。

## 用例：语音工具安装状态与语音触发键

适用范围：当前 macOS Onboarding 的语音工具安装状态与语音触发键流程；原分支 `codex/onboarding-voice-shortcuts-install-state` 只作为历史审计来源。

1. 分别准备豆包、微信、Typeless、Vokie 已安装/未安装的环境。安装状态只能通过公开 Input Sources、NSWorkspace、Bundle ID 或公开 URL Scheme 判断。
2. 首次进入工具页，确认相对排序为豆包、微信、Vokie、Typeless、其他；微信或 Typeless 未安装时对应卡片不显示，安装后回到前台刷新并出现在固定位置。豆包、Vokie 和其他始终显示；都未安装时仍推荐豆包，Vokie 仍显示可选择卡片，但不显示“深度适配”。
3. 页面不显示“快捷键配置来源”“使用推荐配置”“我修改过快捷键”、Command/Option 选择或研发证据状态；本次 staged 语音键固定为 Fn。
4. 在对应工具已安装并可见时依次选择全部工具，确认右栏始终显示步骤 1/2/3/4：豆包、微信、Vokie 使用匹配当前外观的截图，Typeless 与其他工具显示简短说明；第 3 项统一显示“去除系统 Fn 占用”，第 4 项说明清空微信 App 的 Fn 快捷键。
5. Vokie 卡片显示“智能整理，不占用输入法，实时显示文字”，点击 `vokie.com` 只打开官方页面，不改变工具选择或正式配置。
6. 验证默认 Profile：豆包/微信 hold=Fn、toggle=右 Command；Typeless/Vokie toggle=Fn；Onboarding 本次 staged 语音键始终固定为 Fn。
7. 预先把正式语音键设置为左/右 Option 或 Command，选择工具、返回、退出或主动重跑 Onboarding，确认正式配置没有变化。
8. 选择任一工具和任一控制来源后，进入权限页才应用 Fn staged 配置；返回或退出未完成流程后恢复进入前的正式配置。
9. 选择“其他语音工具”时明确要求工具支持语音输入、由用户选择麦克风和完成真实文字测试，不提供快捷键学习路径。
10. staged 结果只在进入后续流程时临时生效；在文字测试前返回或退出，确认恢复旧配置。完成开始、PCM、正常停止、文字上屏及配置确认后，才保存 verified Binding。

选择“其他语音工具”后进入语音测试页：确认页面再次显示所选虚拟音频设备，并提醒用户在第三方工具中开启语音输入、把该设备设为麦克风。未安装或未打开任何支持语音输入的工具时，语音测试不得通过；应显示针对第三方工具未提交文字的恢复说明。

失败判定：默认值被伪装成已检测配置、选择工具或重跑即覆盖正式配置、用户已修改快捷键却仍强制套用默认值、学习路径读取第三方私有配置、退出未完成流程不恢复、或没有真实文字上屏就持久化 Binding，均视为失败。

## 用例：单页控制来源与 Package 门禁

1. 公开仓独立构建只显示小米蓝牙遥控器 2 / 2 Pro，不显示苹果遥控器、Chromecast、Apple App 或网页。
2. 分别使用仅 Siri、仅 Chromecast、仅 Mac Remote 与完整 Package 构建，确认只增加对应入口；完整包显示三个实体遥控器和 Apple 设备 App、网页两个备用入口。
3. 实体遥控器位于主区域且小米强化推荐；iPhone/Apple Watch 合并成一个入口，App 与网页视觉弱化。
4. Chromecast、Apple 设备 App、Web 均可选择 hold/toggle；小米和 Siri 首版只显示 hold。iPhone 与 Apple Watch 分别连接，并验证本次所选模式进入日志和实际会话。
5. 每个来源后续只能由自身的连接、普通按键、语音开始、PCM、停止和文字通过，其他同时在线来源不能代替。

失败判定：缺少 Package 的入口仍可见、Siri 暴露未验证 toggle、App/网页没有 hold/toggle 两种选择、或来源串用通过门禁，均视为失败。

## 用例：Vokie Deep Link 与 SayAll 回流

1. 选择 Vokie toggle + Fn，确认调用 `vokie://launch` 时 action 为 `handsfree-ptt`，未确认 shortcut 编码前不发送 `shortcut`，也不在日志记录 microphoneId。
2. 从浏览器或测试 App 打开 `sayall://launch`，确认 SayAll 激活并恢复当前窗口。
3. 分别回调 `source=vokie&status=received|configured|partial|ready|failed`，确认只更新提示；即使 `ready` 也不能通过真实语音测试。
4. 重复回调、未知 source/status、超长或含空格 reason，确认忽略非法值且不崩溃、不原样记录任意文本。

失败判定：Deep Link 直接把 Binding 标成 verified、绕过 PCM/停止/文字门禁、记录原始查询串或用户文本，均视为失败。

## 用例：升级用户不重复进入 Onboarding

1. 在隔离偏好域中写入任一旧版本应用配置（例如旧的 `buttonBindings`、`selectedAudioDeviceUID` 或 `peripheralIdentifier`），不写入 `launch.lastLaunchedBuild`、Sparkle 启动标记和 `onboarding.*` 状态。
2. 使用当前版本首次启动，确认直接进入主设置页，`onboardingCompletedVersion` 被迁移为当前版本，不显示欢迎页。
3. 使用完全空的偏好域首次启动，确认仍进入完整 Onboarding；在欢迎页退出后再次启动，确认恢复原步骤而不是被误判为非首次安装。
4. 使用已完成 Onboarding 的用户升级，确认只进入主设置页；若权限缺失，沿用权限修复页，不重跑完整向导。
5. 额外覆盖已存在 `onboarding.migrationVersion`、但没有安装状态迁移标记的旧用户，确认仍按已有配置跳过完整 Onboarding。

失败判定：已有旧配置的用户进入欢迎页、真正全新的用户第二次启动被自动标记完成、或主动“重新运行设置向导”被该判断阻止，均视为失败。

自动化边界：状态机、持久化、公开 API 检测和页面源码可自动测试；第三方输入法真实注册、Command 快捷键是否被目标 App 接受、真实遥控器/手机语音文字上屏，以及 Sparkle/PKG 升级仍需用户真机验收。

## 用例 0：旧安装迁移与全新安装边界

1. 在测试账号安装并正常启动 `1.8.7 (68)`，保留至少一项可辨认的连接、按键或界面设置。
2. 通过 Sparkle 升级到 `1.8.10 (102)` 候选并首次启动。
3. 确认直接进入主面板，不显示欢迎页，且原有设置仍保留。
4. 使用没有任何无线麦偏好记录的新测试账号首次启动同一候选，停留在欢迎页后退出并再次启动。
5. 确认全新账号两次启动都处于 Onboarding，不能进入主面板。
6. 在新账号选择语音工具并进入任一中间步骤，退出并升级到更高测试 Build，确认恢复原步骤。
7. 完成向导后从“关于”页主动选择“重新运行设置向导”，再次启动并确认仍进入欢迎页。

预期结果：旧版本已经安装使用的用户只进行一次无界面迁移并直接使用 App；真正全新安装、中途未完成和主动重新运行三种状态均不会被旧安装证据误跳过。

失败判定：旧用户被要求重新设置、旧设置丢失、全新用户第二次启动绕过向导、中途进度被标记完成，或主动重新运行后直接返回主面板。

升级用户补充：如果完成更新后的首次启动实时发现蓝牙、输入监控或辅助功能缺失，应直接打开现有设置窗口的“设置”页并定位到“权限与隐私”区，让用户补授权；不重置 Onboarding 完成状态，也不要求重跑遥控器、音频、语音或普通按键步骤。权限全部正常时仍保持原更新完成页面行为。

## 用例 1：启动门禁、不可跳过与恢复

1. 全新状态启动 App。
2. 启动后不移动窗口，确认 Onboarding 以完整 `1020 × 772` 窗口显示在 macOS 系统居中位置，四边均未超出菜单栏、Dock 或屏幕边缘。
3. 检查顶部只显示“准备 › 设置 › 试一下”，页面没有步骤编号、总数、百分比、“跳过”或“稍后继续”。
4. 在欢迎页关闭窗口，再从菜单栏打开；应仍停留在欢迎页。
5. 选择一个语音工具、当前有无遥控器及必要的手机控制方式并进入权限页，退出 App 后重新启动。
6. 确认直接恢复到权限页，语音工具、遥控器状态和最终控制方式都保留，不能看到主设置页。
7. 在任一未满足门禁的页面尝试继续。

预期结果：未完成当前流程版本时每次启动都显示完整且居中的向导；关闭窗口和退出 App 只保存当前位置，不构成旁路；缺少实时条件时主按钮禁用。

失败判定：窗口从屏幕角落出现、任一边越出当前屏幕可用区域、页面被窗口边缘裁切、能打开主设置页、存在跳过/稍后入口、重启回到错误页面、只点击系统设置就被判定成功，或欢迎页出现前主动弹出系统权限。

2026-08-24 窗口回归记录：正式 1.9.8 (131) 的隔离 Bundle ID 空偏好域稳定复现 `980 × 764 @ (755,252)`，右侧和底部越界；修复版空偏好域首次启动、写入原始异常 `1 × 1` autosave frame 后重启，以及已完成 Onboarding 的设置页，均得到系统居中的 `1020 × 772 @ (246,59)`。欢迎页真实窗口截图完整，无内部滚动或裁切。外接显示器、低于设计最小尺寸的缩放分辨率和 Intel Mac 仍需单独复验。

## 用例 2：输入工具与安装状态

分别从头运行豆包输入法、Vokie、其他语音工具，以及已经安装时的微信输入法和 Typeless。

预期结果：

- 未选择工具时不能继续；当前可见工具卡按两列铺开、等高并顶部对齐，`1020 × 772` 下不依赖页面内部滚动。
- 输入工具卡片保持豆包、微信、Vokie、Typeless、其他的相对顺序；微信和 Typeless 未安装时不显示，安装后出现在各自固定位置，不得因为当前输入源变化而重新排序或移动选中卡片。
- 没有检测到任何已安装工具时显示豆包推荐安装；豆包、Vokie 和其他仍显示，Vokie 不显示“深度适配”或伪造安装完成。
- 选择豆包或微信时只更新卡片选中态，不调用系统输入源切换 API，也不自动打开系统设置；离开工具页、回到前台或聚焦语音测试输入框时不重复触发。
- 工具页不显示配置来源或学习路径；所有工具的 Onboarding staged 语音键统一为 Fn，控制来源仍可选择按住/按一次语义。
- 能力矩阵中的默认快捷键只用于后续配置说明；Onboarding 本次 staged 语音键始终固定为 Fn，不因工具默认值或用户历史配置改变。
- 工具页选择和重跑 Onboarding 不立即改动正式 `VoiceKeyMode`、Fn 点按开关或 Chromecast 模式；只有下一页同时选定控制来源并确认配对计划后才能进入 staged 状态。
- 选择“其他语音工具”仍使用 Fn staged 配置，并在语音测试页要求用户确认目标工具的语音快捷键和麦克风；Onboarding 不提供快捷键学习或配置来源选择。
- 选择任一可见工具后右栏都显示步骤 1/2/3/4，第 3 项始终显示“去除系统 Fn 占用”；Vokie 使用对应浅色/深色截图并显示官方简介与网址。

失败判定：未安装的微信或 Typeless 仍显示、已安装后没有显示、未安装 Vokie 被隐藏、卡片相对顺序变化、选择没有保存、卡片因输入源变化跳动、默认值被写成“已检测到当前配置”、工具选择立即覆盖正式语音键、未知 hold 快捷键仍被自动采用、选择 Radio 就弹出系统设置、离开选择页后重复切换输入源、页面裁切，或退回旧的 Fn-only 文案，均视为失败。

## 用例 2A：完成后按已验证 Binding 准备输入工具

分别用豆包输入法、微信输入法、Typeless、Vokie 和其他语音工具完成 Onboarding，并覆盖 Fn、左/右 Command 与左/右 Option：

1. 完成后切换到 ABC 或另一个非目标输入源，并让无线麦在后台运行。
2. 用本次已验证 Binding 从所选控制来源开始语音，观察输入源，再完成一次真实语音输入。
3. 结束语音，手动切换回其他输入源，再重复一次。
4. 保持目标输入法已经选中，再开始一次语音。
5. 对 Typeless、Vokie 和其他语音工具重复上述操作。
6. 重新启动无线麦后再次执行豆包或微信分支。

预期结果：豆包和微信在真实语音会话开始时使用精确 ID 准备已经启用的目标输入法，不依赖 Binding 是否为 Fn；同一会话只准备一次，目标输入法已经选中时没有可见抖动。会话结束时，如果用户没有主动改选其他输入法，恢复语音开始前的输入源；用户在语音期间主动改选后不得覆盖。退出并重启后仍记住所选工具和 verified Binding。Typeless、Vokie 和其他工具不切换系统输入源。无线麦不拦截或假设 `Control + Space` 及其他输入法快捷键。

失败判定：按显示名称误选相似输入法、Command/Option Binding 不准备豆包或微信、一次会话重复切换、日常路径重复弹出“是否启用”确认、非输入法工具也切换系统输入源、切换失败阻断录音、结束时覆盖用户主动选择、旧会话恢复新会话的输入源、重启后丢失 Binding，或只有 App 前台时可用。

## 用例 2B：单页控制来源、Package 门禁与分支隔离

1. 使用公开仓独立构建进入控制来源页，确认只显示“小米蓝牙遥控器 2 / 2 Pro”。
2. 分别注入 Apple Remote、Chromecast、Mac Remote Package；确认只增加对应入口。完整包显著显示小米、苹果第 6 代、苹果第 7 代；Chromecast、Apple 设备 App、网页版收在默认折叠的“更多控制方式”。
3. 不选择任何来源时不能继续；小米遥控器始终带推荐标记，但不得自动替用户覆盖已明确选择的其他来源。
4. 小米和 Siri 只使用已验证 hold 能力；Chromecast、Apple 设备 App、Web 提供 hold/toggle。iPhone、Apple Watch、Web 分别选择两种模式并确认配对摘要与日志一致。
5. 对推荐路径核对“来源能力 × 工具模式 × 默认快捷键”的解析结果；对学习路径进入权限页后捕获当前快捷键，并明确选择该工具采用 hold 或 toggle。
6. 进入后续页后返回控制来源页，确认 staged 配置被丢弃并恢复进入 Onboarding 前的正式语音键、Fn 点按和 Chromecast 模式。
7. 改选来源后，确认旧来源的连接、普通按键和语音状态不能直接让新来源通过。
8. 只有公开构建且已存在小米遥控器生产连接时可自动选择小米并进入权限页；完整包存在多个实体选项时不得猜测型号或自动跳过选择页。
9. 从“设置”页重新运行向导，确认控制来源恢复为未选择，但现有受信任设备、按键映射、音频选择和正式语音配置仍保留。

预期结果：控制来源在一个页面完成，实体硬件为主、App/Web 为备用；页面只显示当前构建真正包含的能力。新配置先 staged，真实语音文字验证后才 verified；同一时间只有所选来源能点亮连接、普通按键和语音检查。

失败判定：缺少 Package 的入口仍出现、页面退回两层选择、Siri 暴露未验证 toggle、iPhone/Watch/Web 缺少 hold/toggle、选择或重跑立即覆盖正式配置、返回不回滚、未连接时提前触发权限、其他在线来源可代替通过，或完整包自动猜错实体型号。

## 用例 3：所有控制来源开启完整权限并完成学习

分别在当前构建可见的每个实体遥控器、Apple 设备 App 和网页版分支，对蓝牙、输入监控和辅助功能执行“未决定 → 拒绝 → 从系统设置恢复 → 允许”：

1. 点击每一行唯一的权限操作。
2. 拒绝权限并返回 App，确认该行仍未通过且不能继续。
3. 从页面打开正确的系统设置，允许权限，再切回 App。
4. 如系统要求重启 App，退出并重启，确认仍恢复到权限页并重新检测。
5. 三项均显示已授权后，依次点击蓝牙、输入监控和辅助功能整张卡片，确认分别打开系统设置中的蓝牙、输入监控和辅助功能隐私页。
6. 每次返回 App 后确认权限仍显示已授权，点击卡片本身没有改变状态、重新触发无序弹窗或打断现有蓝牙连接。
7. 三项权限完成后确认 staged 配置仍固定为 Fn；返回工具或控制来源页、退出未完成流程时正式快捷键不被覆盖。
8. 对“来源只支持 hold、工具使用 toggle+Fn”的组合确认开启 Fn 点按转换；toggle+右 Command 等当前硬件无法转换的组合必须明确拒绝，不能静默改键。

预期结果：每个可见来源都必须在三项权限全部实时有效后才能继续；未授权和已授权状态下整张权限卡都可进入对应系统设置；Apple 设备 App/网页版页面额外说明本地网络会在下一页通过真实连接验证；返回前台或重启后自动刷新。学习路径只捕获用户主动按下的公开键盘事件，不读取第三方工具配置。

失败判定：任一来源缺少任一权限仍通过、Apple 设备 App/网页版没有显示完整三项权限、已授权卡片无法点击、打开错误设置页、点击已授权蓝牙导致连接重建、状态不刷新、学习前即可继续、捕获不支持的修饰键仍通过，或系统权限窗口连续无序弹出。

### 正式签名改名权限连续性

1. 在独立测试账号安装正式 Developer ID 签名的旧版 `Remote Mic.app`，完成蓝牙、输入监控和辅助功能授权，并逐项完成真实功能验证。
2. 不清除 TCC、不手动移除旧权限，通过正式升级路径安装同一 Team 和 Bundle ID 的 `SayAll.app`。
3. 首次启动后检查系统设置中的三项权限，并验证蓝牙连接、实体按键和辅助功能动作。
4. 从 Onboarding 或“关于”页重新运行向导，确认权限页直接显示三项已授权，且三张卡仍可打开对应系统设置。

预期结果：正式升级前后保持 `com.hd838a.RemoteMic`、`RemoteMic` 可执行文件和相同 Developer ID designated requirement 时，仅 App 文件名或显示名从 Remote Mic/无线麦变为 SayAll/无线麦不会要求重新授权。

失败判定：同一正式代码身份升级后权限条目丢失、真实能力不可用、必须删除权限记录或重启机器才能恢复，或新包的 Bundle ID、Team ID、designated requirement 与旧包不同。

验证边界：本地 ad-hoc 包没有正式 Team ID，不能继承正式包权限，不能用于本用例的通过判定；第三方重签名包同样不在支持范围内。

## 用例 4：遥控器连接与实体按键

1. 从系统蓝牙中取消 RC003 配对，进入连接页。
2. 确认页面明确显示首次连接顺序：先长按 TV 键约 2 秒，直到遥控器底部白灯闪烁；再同时长按 Home + Menu 进入蓝牙配对。
3. 确认 App 显示等待连接且不能继续。
4. 按页面提示激活遥控器并完成系统配对，等待 App 实际连接。
5. 只连接但不按键，确认仍不能继续。
6. 确认按键卡在任何输入到达前就明确要求短按圆盘中间确定键或方向键，并明确写明不要按麦克风/语音键；不能只显示“按键功能已连接”。
7. 按下并松开麦克风/语音键，确认页面立即显示“刚才按的是语音键”和正确操作，仍不能继续；复制诊断，确认语音键计数增加、普通控制键计数仍为零、最后输入为 `voice`。
8. 按一个普通实体按键，确认纠正状态消失、页面显示已收到并允许继续；复制诊断，确认普通控制键计数增加、最后输入为 `control`。
9. 在系统蓝牙已连接、语音连接仍显示准备中的状态按普通实体键，确认页面改为“已识别实体遥控器”并允许进入音频页；保持 App 运行，确认后台继续恢复语音连接。
10. 到语音测试页按住语音键；如果语音 bridge 尚未 Ready，确认仍不能通过开始、PCM、停止和文字门禁，恢复后再完成一次真实语音。
11. 断开遥控器、重新连接后重复。

预期结果：首次连接说明完整显示且顺序明确；系统蓝牙列表中的“已连接”不能替代 App 实际连接；普通键与语音键的操作提示、即时反馈和诊断事实明确区分。必须收到生产 HID 链路验证的普通实体按键事件。该按键可以在连接页证明实体控制已识别，但不能替代后续真实语音链路验证，完成页仍要求当前语音连接可用。

失败判定：遗漏 TV 键激活或 Home + Menu 配对提示、按键名称或顺序错误、文字裁切，等待状态没有明确排除语音键、误按语音键后仍显示无响应或允许继续、诊断无法区分误按语音键与完全无输入、未收到生产遥控器按键即可继续、普通键盘能冒充遥控器、语音键误算普通按键、HID 按键已收到后仍必须重启才能继续、没有真实语音流却完成，按键被两只遥控器重复计数，或重新查找导致 App 卡死。

## 用例 4A：未完成 Onboarding 用户升级后的首次连接恢复

1. 在 `1.8.8 (100)` 或 `1.8.9 (101)` 明确开始但不完成 Onboarding，停留在遥控器页并保持 RC003 已配对。
2. 通过与用户一致的 Sparkle 更新路径升级到包含本修复的候选版，不清除向导进度。
3. 首次启动后进入 Onboarding 遥控器页，按一个普通实体按键。
4. 如果页面短暂出现“已收到实体按键”但仍显示正在查找，保持 App 运行并等待自动恢复，不执行重启。
5. 连接后按普通按键，再执行一次普通 `STREAM_START → AUDIO → STREAM_STOP` 语音输入。
6. 断开遥控器并返回该页，点击“重新查找”，确认即使此前没有可重连的 bridge 也会重新启动发现。

预期结果：实体按键已到达但 BLE 尚未 Ready 时只触发一次恢复，不因连续按键反复重连；无需重启 App 即转为已连接；普通按键和 RC003 语音基线保持正常。日志在空 bridge 恢复时出现一次 `BLE RECONNECT starting_missing_bridges`。

失败判定：状态一直停留到重启、每次按键都中断并重新建立连接、点击“重新查找”仍无新连接尝试、连接恢复后普通按键或语音失效，或稳定已连接状态被额外重连。

## 用例 4B：新配对遥控器发现与部分 HID service 恢复

1. 保持 App 停留在 Onboarding 遥控器页，从页面打开系统蓝牙设置。
2. 取消旧遥控器配对，再配对一只新的 RC003；确认系统显示已连接。
3. 不退出 App，直接切回 Onboarding，观察页面是否开始新的 discovery 并显示新遥控器。
4. 按方向、确定和音量键，确认无线麦均收到普通按键；再按语音键完成一次普通 `STREAM_START → AUDIO → STREAM_STOP`。
5. 如同时保留 RC001 与 RC003，交替按两只遥控器，确认各自只驱动自己的配置。
6. 检查日志：允许出现某个旧 service 写入失败，但当前安全设备应出现 `power_suppressed=true suppression_scope=locations=`，且不再因 `matched=2 applied=1` 拒绝全部 HID。
7. 按一次已映射的电源键，确认只执行配置动作且系统不锁屏、不弹关机确认。
8. 制造按键监听失败或撤销权限，确认“等待实体按键”卡片显示生产 HID 错误；恢复条件后点击“重新检测按键”，无需重启 App 即重新建立监听。

预期结果：从系统设置返回后无需重启 App 即发现新设备并重建 HID；部分失败只隔离不安全 Location，安全遥控器普通按键继续工作，电源键保护保持有效；按键失败原因和重试入口在当前页可见。

失败判定：仍需重启才能显示、BLE Ready 后普通按键无响应、安全设备也被全局拒绝、失败设备仍被 App 接管，或出现锁屏/关机系统动作。

## 用例 4B-1：未绑定遥控器的首份 HID 报告

1. 使用新的 macOS 测试用户或隔离偏好域启动未完成 Onboarding 的候选版，确保遥控器 Profile 尚无 HID fingerprint。
2. 连接一只 RC001 或 RC003，确认 BLE Ready、输入监控和辅助功能均正常。
3. 检查日志出现 `HID DEVICE probing mode=monitored`，且在按键前不会因为系统枚举顺序直接绑定 Profile。
4. 短按方向键或 OK 键，确认日志依次出现 `HID CONNECTED mode=probed`、`HID REPORT accepted` 和 `HID EDGE pressed=`，页面立即显示已收到按键并允许继续。
5. 点击“重新检测按键”、断开后重连并重复，确认不再持续出现 `discovery_waiting_for_report` 且无需重启 App。
6. 同时连接两只尚未绑定的遥控器，先按第二只，再按第一只；确认第一份真实报告决定对应 Profile，随后新的 discovery 仍能识别剩余遥控器，两只设备不会重复执行同一动作。
7. 按电源键，确认只执行配置动作且 Mac 不锁屏、不弹关机确认。

预期结果：discovery 会以非独占模式探测所有安全候选，首份真实报告选择实际操作的设备，不再形成“等待报告后才打开设备”的闭环；双遥控器隔离、电源键保护和首按不丢失保持不变。

失败判定：日志只有重复 `HID DEVICE deferred reason=discovery_waiting_for_report`、系统响应按键但 App 无任何 `HID REPORT`、系统枚举的第一只遥控器错误抢占 Profile、首个按键被消耗、两只遥控器重复执行，或电源键触发系统动作。

## 用例 4B-2：第三方输入工具占用 HID

1. 在没有第三方 HID 工具接管遥控器的环境中完成用例 4B-1，确认普通按键可被发现。
2. 安装并运行 Karabiner-Elements，在“设备”中找到“小米蓝牙语音遥控器”，开启该设备的 “Modify events”。重新进入 Onboarding 遥控器页并点击重新检测。
3. 确认页面显示“遥控器被其他输入工具占用”，而不是泛化的权限失败；日志出现 `reason=exclusive_access` 和 `karabiner_installed=true`。
4. 关闭 Karabiner-Elements 中该设备的 “Modify events”，或将该设备设为 “Ignore”，回到 SayAll 后点击重新检测。
5. 确认无需重启 App 即可出现 `HID DEVICE probing`、`HID CONNECTED` 和真实 `HID REPORT`，普通按键可以继续 Onboarding。
6. 在 Karabiner-Elements 已安装但没有管理该遥控器的环境中重复，确认不会因为“已安装”本身阻止正常连接。
7. 使用其他 HID 映射工具占用设备，确认显示通用占用提示，不把根因错误归因于 Karabiner-Elements。

预期结果：只有真实 `kIOReturnExclusiveAccess` 才触发第三方占用提示；Karabiner-Elements 安装状态只决定是否补充专项操作步骤，关闭占用后可以通过重新检测恢复。

失败判定：没有区分独占错误、把 Karabiner 安装误判为正在占用、要求重启 App、仍显示权限错误，或关闭 “Modify events” 后无法恢复。

## 用例 4C：iPhone App 与无 iPhone 网页版

### iPhone App

1. 选择“使用 iPhone App”，进入连接页并点击安装或打开 iOS App。
2. 完整构建确认右栏显示当前监听周期的动态配对二维码；公开构建确认右栏显示随包交付的 App Store 下载二维码（见“iPhone 右栏 App Store 下载二维码回归”）。保持 iOS App 在前台并扫描二维码，核对校验码并在 Mac 批准首次连接。
3. 只连接不按键，确认不能继续；在 iPhone 遥控器按一个普通按键后才允许继续。
4. 断开并重新连接，确认无需重启 Mac App；同时保持实体遥控器在线，确认实体按键不能代替 iPhone 通过。
5. 拒绝 iPhone 相机权限或让二维码过期，确认 iPhone 仍自动使用 Nearby/Bonjour 发现，不要求开关 Wi-Fi 或重启手机。

### 没有 iPhone 的网页版

1. 使用本地测试包前先确认 Bundle 已包含发布流程注入的 Web Relay 配置；选择“使用网页版”，确认右栏生成二维码；用手机 Safari 扫码，点击连接 Mac，并在 Mac 批准本次连接。
2. 只建立网页连接不按键，确认不能继续；在网页版按一个普通按键后才允许继续。
3. 关闭浏览器页面后重新生成二维码并重连，确认无需重启 Mac App。
4. 同时保持 iPhone 或实体遥控器在线，确认它们的按键不能代替网页版通过。

预期结果：iPhone 优先使用二维码中的局域网地址直连当前 Mac 监听周期，失败时自动回退 Nearby/Bonjour；网页版使用真实 WSS 会话。连接和普通按键都来自当前所选方式。没有 iPhone 的用户不需要安装 App 即可继续，但不能跳过真实连接。

失败判定：iPhone 二维码无法生成或扫码失败后不再自动发现、页面要求必须有 iPhone、只显示已连接即可继续、其他来源按键误通过、首次批准无反馈、断连后只能重启恢复，或网页版另开 Sheet/Popover 才能完成主要步骤。

## 用例 5：音频回环设备选择

1. 同时安装 MiRemoteV 2ch 和 BlackHole 2ch，进入音频页并点击重新检查。
2. 确认页面只展示 MiRemoteV 2ch 和 BlackHole 2ch；蓝牙扬声器、Beosound 和其他普通系统输出不会成为 Onboarding 选项。
3. 分别选中 MiRemoteV 2ch 与 BlackHole 2ch，确认两者都能满足设备选择门禁；实体遥控器路径仍需等待所选设备音频输出就绪。
4. 保持主设置中选中 Beosound、蓝牙扬声器或其他普通设备，确认向导要求改选受支持虚拟音频设备且不能继续。
5. iPhone App 和网页版分别选中 MiRemoteV 2ch 与 BlackHole 2ch；不开始手机语音，确认页面说明“语音开始时连接音频”并允许进入真实语音测试，而不是要求先说一次话。
6. 将当前选中的受支持设备删除或停用，再点击重新检查，确认实体、iPhone 和网页三条路径都不能继续；改选仍存在的另一种受支持设备后恢复。
7. 停留在本页切换到音频驱动安装或系统工具，重新启用虚拟音频设备后直接切回无线麦，不点击按钮，确认页面自动刷新。
8. 明确区分两端配置：本页选择 `MiRemoteV 2ch` 或 `BlackHole 2ch` 只代表 SayAll 把遥控器/手机声音输出到该设备；随后还必须在豆包、微信输入法、Typeless 或其他语音工具自己的设置中，把同一个设备选为麦克风。本页选择成功不得被描述为已经修改第三方工具麦克风。
9. 对 MiRemoteV 2ch 分别把 input/output scope 主声道设为 `mute=1 / volume=0` 和 `mute=0 / volume=0.19`，再开始测试音或真实语音；确认 SayAll 只对该受支持虚拟设备自动解除静音并把低于 `0.2` 的音量恢复为 `1.0`。重复设置为 `volume=0.20` 和 `0.25`，确认 SayAll 不覆盖阈值及以上音量。若使用测试命令，必须先保存原值并在测试结束后读回确认已恢复。
10. 对不公开 mute/volume 属性的受支持虚拟设备，确认属性状态记录为 `unknown`，设备不会仅因此被错误拒绝；对普通扬声器、实体麦克风和未知设备，确认 SayAll 不写入其静音或音量属性。

预期结果：三条路径都要求 MiRemoteV 2ch 或 BlackHole 2ch 存在且被实际选中。明确静音或音量低于 `0.2` 的受支持虚拟设备在配置或语音开始前自动恢复，阈值及以上音量不变；无法恢复时设备不能被标为 Ready。实体遥控器还要求持续音频输出就绪；iPhone/网页版使用按需输出，手机开始语音时才连接所选虚拟设备，并由下一步的真实声音、停止和文字测试确认完整链路。

失败判定：BlackHole 2ch 无法选择或继续、Beosound/扬声器等普通设备可以通过、受支持设备未选择或已失效仍可继续、实体遥控器输出未就绪仍继续、iPhone/网页版必须先开始一次语音才能离开音频页、静音/低音量修复后仍被报告为 Ready、`volume>=0.2` 被覆盖、普通实体设备的静音/音量被修改，或向导修改/删除用户主设置中的其他音频设备。

## 用例 6：真实端到端语音文字

对豆包输入法、微信输入法、Typeless 和其他工具分别执行，并分别使用实体遥控器、iPhone App 和网页版：

1. 从音频页进入语音测试页，确认出现不可忽略的“输入工具还必须选择同一个麦克风”检查卡。卡片必须同时显示 SayAll 当前选择的设备和语音工具名称，并明确说明 SayAll 音频页不会修改第三方工具设置。
2. 确认输入框附近显示“调整声音增益”说明和 0–24 dB 滑块；0 dB 表示保持原始音量，调高会同时放大人声和环境噪声。
3. 先保持当前值说一句正常音量的话，再把增益调到 6–12 dB，说一句小声或气声的话；确认滑块值变化后立即用于下一次语音，不需要离开页面或重启音频。
4. 在同一张卡片上核对并记录全部配置：SayAll 当前 staged Binding 的快捷键与 hold/toggle、SayAll 音频输出设备（MiRemoteV 2ch 或 BlackHole 2ch）、第三方工具语音识别键与模式，以及第三方工具麦克风。豆包还必须显示并确认“全局唤起语音”；不得固定写成所有工具都使用 Fn。
5. 打开所选语音工具的公开设置界面，把语音识别键和麦克风设为卡片显示的值，再逐项勾选用户确认。切换语音工具或返回音频页改选设备后，原确认必须自动失效；未重新确认时，即使文字测试通过也不能继续。
6. 对豆包输入法额外确认“豆包输入法设置 → 语音输入/麦克风选择”为 `MiRemoteV 2ch`（或本次明确测试的 `BlackHole 2ch`）。用户已在 `1.9.19 (172)` 现场确认：豆包选错麦克风时无文字，手动改为 `MiRemoteV 2ch` 后恢复。
7. 不点击输入框，确认光标已经位于输入框内；光标与占位符的文字起点应对齐。
8. 按本次来源与 Binding 的真实语义开始语音：hold 模式按住并在说完后松开，toggle 模式按一次开始、再次按一次停止；说“无线麦已经连接成功”。
9. 切换到另一个 App，再返回无线麦；不点击输入框，重复一次语音输入。
10. 点击“重新测试文字输入”，不再手动点击输入框，重复一次语音输入。
11. 观察实时检查：语音键完整按下并松开、收到所选来源真实声音、当前选择的音频回环设备正常、文字出现。
12. 保持另一种控制方式同时在线并发起语音，确认不能替当前所选方式点亮开始、样本或结束检查。
13. 分别制造以下失败：只触发会话但不产生音频、音频设备失效、开始后不松开、没有文字上屏。
14. 完成一次有开始、PCM 和松开结束但没有文字的语音会话，然后直接用 Mac 键盘在输入框中键入或粘贴文字；确认“文字已经出现”仍未通过，并提示重新测试语音输入。
15. 不点击重试直接开始下一次真实语音；确认新会话开始时旧的手动文字被清空，真实语音写入后才能继续。
16. 在语音过程中确认输入框出现临时文字后松开语音键；预期输入框仍保留这段文字，输入法临时组合态被提交为普通文字，不需要按回车或再次点击输入框，且“继续”可以按正常流程判断。
17. 对豆包、微信输入法、Typeless 和其他工具重复第 14–16 步；若任一工具无法继续，记录故障时间和 `runtime.log`。日志允许记录无线麦自身 PID 以区分实例，但不得包含输入事件来源 PID、键码、输入文字或前台 App。
16. 使用“活动监视器”记录无线麦进程 CPU，在语音测试页可见、完成向导后的设置页可见、设置窗口打开后再关闭三种状态下，各执行一次至少 30 秒的连续真实语音。
17. 分别记录三种状态的平均 CPU、峰值 CPU、音频批次数、样本数和 `enqueue_failures`；如果仍持续接近占满一个 CPU 核心，再采集同一时段的 Time Profiler 调用树。
18. 完成一次“开始、PCM、松开结束均正常但没有文字”的会话，确认松开后的 3 秒等待窗口内不显示终态失败；窗口结束后只出现一个原因，不再依次出现 `voice.no_samples → voice.session_not_ended → voice.no_transcript`。
19. 在每个 Onboarding 步骤进入、通过、阻断、重试、恢复和完成时检查 `runtime.log` 已实时出现对应的 `ONBOARDING STEP` 或 `ONBOARDING EVENT`；再复制 Onboarding 诊断，确认剪贴板和日志都包含同一份 `diagnostic_schema=3` 摘要。日志中应出现 `ONBOARDING DIAGNOSTICS BEGIN`、逐行 `FIELD` 和 `END`，当前 attempt 包含 App/Build/系统完整身份、`voice_attempt`、`voice_trigger_path`、输入框焦点丢失次数/维度/恢复/截止状态、首样本延迟、会话时长、文字等待时长，以及 `voice_audio_generation`、音频路线、收到/调度/实际播放/中断/pending 样本、入队失败、所选/实际设备稳定类型和绑定状态。
20. 制造一次中间瞬时失焦但三秒截止前已恢复的会话，确认不会被归类为 `voice.input_target_focus_lost`；截止时仍失焦才允许使用该失败码。
21. 制造一次 SayAll 音频完整送达、焦点稳定但没有文字的会话，确认日志为 `voice.external_tool_no_commit`、`voice_probable_cause_confirmed=false`、`voice_external_tool_microphone_observable=false`，并把 `microphone_matches_selected_device` 列为首个检查项。
22. 制造入队失败、实际设备绑定错误、播放中断和截止时仍 pending，分别确认归类为 `voice.audio_delivery_failed`，且不会被第三方工具失败覆盖；正常排空中的 pending 不得在三秒截止前提前失败。
23. 快速连续执行两次语音，确认第二次的 `voice_audio_generation` 不同，上一会话迟到的播放完成/中断数量不会进入第二次。

预期结果：首次进入、从其他 App 返回以及点击重试后，原生 `NSTextView` 都由当前窗口确认成为 `firstResponder`；无需额外点击即可让所选语音工具写入文字。只有当前所选来源的会话开始、PCM 样本数量大于零、松开后会话结束、所选 MiRemoteV 2ch 或 BlackHole 2ch 有效、单次 attempt 进入 `passed` 且文字由语音工具写入时才允许继续。进行中的正常阶段不写失败历史，每次 attempt 只产生一个 `passed` 或 `failed` 终态。每次会话的首个非空音频批次即可点亮样本检查，后续批次不会造成约 60 Hz 的整棵设置视图无效化；连续语音期间进程 CPU 不应再持续接近占满一个核心。只有确认来自 HID 系统且无用户进程来源的物理 `keyDown` 会标记手动输入；合成、combined/private、未知来源或缺少 CGEvent 的文字全部 fail-open。无线麦不读取第三方语音工具内部状态，也不记录音频内容、输入框文字或长度、输入事件来源 PID、键码、蓝牙地址、设备 UID 或前台 App。

补充运行状态与配对切换检查：

1. 对 Vokie 和 Typeless 分别关闭目标 App，再返回语音测试页；确认 SayAll 尝试在后台打开目标 App，并显示可理解的运行状态提示。若自动启动失败或目标仍未运行，页面阻止完成并提供“重新打开”；启动后状态应自动刷新，随后仍必须通过真实语音会话和文字确认。
2. 在支持的控制来源上切换 hold/toggle；确认旧试用 Binding 被恢复，新的配对摘要和无线麦 Fn/点按转换状态同步，继续按钮按当前状态重新计算。
3. 选择 Typeless 或 Vokie 后进入语音测试页；确认 SayAll 尝试后台启动目标 App，但不抢走输入框焦点。自动拉起失败、状态未知或目标 App 仍未运行时，页面提供“重新打开”并阻止完成；目标运行后门禁自动恢复。

补充失败判定：语音键松开后已经显示的文字消失，或必须按回车/再次点击输入框才能保留文字，均视为失败；目标 Vokie/Typeless 未运行时没有主动拉起、拉起失败后仍允许完成，或没有提供“重新打开”，均视为失败。

自动化兼容门禁：Onboarding 文字监听必须保持 macOS 13 可编译，Intel Ventura Release 构建不得使用仅 macOS 14 可用的双参数 `onChange` 重载。

失败判定：没有显示双端配置区别、未确认第三方工具麦克风仍能继续、切换工具/设备后旧确认仍有效、把用户勾选伪装成自动检测、页面显示焦点边框但 `NSWindow.firstResponder` 不是当前输入框、返回 App 或重试后必须再次手动点击、光标与占位符错位、只有 `STREAM_START` 就通过、没有语音文字仍通过、终态失败后迟到文字绕过新 attempt 直接继续、一次 attempt 写入多个失败、瞬时失焦恢复仍误报为持续失焦、正常 pending 被提前判失败、连续 generation 计数串线、键盘输入可以点亮文字检查、任一真实语音工具的文字被误判为手输、未知来源被强制阻塞、松开后仍在收音、连续语音期间 CPU 仍稳定接近占满一个核心、文字出现在其他窗口却误判，或日志包含音频内容、测试文字或长度、输入事件来源 PID、键码、设备 UID/自定义名称或前台 App。

## 用例 7：三个普通按键与完成

1. 在按键页使用当前所选控制方式重复按同一个普通按键三次。
2. 确认只算一个已体验按键且不能继续。
3. 再按两个不同普通按键。
4. 进入完成页，点击“打开无线麦”。
5. 确认进入当前侧边栏第一项（当前顺序为“按键”）；退出并重启不再出现向导。调整侧边栏顺序后，此处应自动进入调整后的第一项，而不是固定进入某个页面。
6. 在主面板记录当前语音输出设备、按键映射、Dock、启动和预发布更新设置。
7. 在“关于”页点击“重新运行设置向导”，确认立即回到欢迎页，重启后仍处于向导。
8. 重新完成向导并返回主面板，确认第 6 步记录的现有设置仍保留。
9. 再运行三次流程，在完成页分别撤销当前分支必要权限、断开实体遥控器/iPhone/网页版、停用所选音频输出，确认“打开无线麦”立即禁用；恢复对应实时条件后按钮自动可用。
10. 停留在完成页退出并重启 App；确认不会因之前语音/三个按键的视图临时状态清零而永久卡死，但当前分支权限、控制连接和音频仍必须有效。
11. iPhone/网页版完成真实语音后保持手机语音已停止，确认按需音频已经释放时“打开无线麦”仍可点击；移除所选音频设备后按钮必须立即禁用。

预期结果：“关于”页明确说明重新运行只用于复查权限、控制方式、语音输出设备和语音输入，不会清除现有连接、按键映射或其他设置；最终进入主界面前再次确认当前分支权限、控制连接和音频仍可用。

失败判定：重复同一按键可通过、语音键被计入、运行时已经失效仍能完成、视图重建后无恢复路径、完成按钮不进入设置、完成版本未保存、重新运行仍可绕过向导，或重新运行后现有用户配置丢失。

补充检查：普通按键页必须忽略已有映射。先在设置中为一个方向键配置单击、双击或长按动作，再从“关于”重新运行 Onboarding；进入普通按键页后按下该键，确认只点亮本次普通按键观察，不执行原动作，也不读取或覆盖原配置。分别对小米、苹果、Chromecast、iPhone/Apple Watch 和 Web 分支检查；重复同一键仍只计一次。

补充检查：实体遥控器已连接但普通按键无事件时，在密码输入或安全键盘应用保持安全输入开启约 3 秒，确认页面显示“系统安全输入可能影响遥控器按键”及“重新检测”，不显示进程、PID 或内部术语。退出该应用后点击“重新检测”，确认 HID 重新应用；安全输入释放后仍必须收到真实普通按键才能继续。iPhone/Apple Watch 和 Web 分支不显示该提示。

## 用例 8：布局、语言与稳定功能回归

- [ ] 中文与英文在 `1020 × 772` 下逐页检查，无文字或按钮裁切，无意外窗口尺寸变化。
- [ ] 英文输入工具卡固定显示 `Doubao`、`WeType`、`Vokie`、`Typeless`、`Other Voice App`；页面不得出现 `Doubao Input Method`、`WeChat Input Method`、`Another Voice Tool` 或普通用户含义不清的 `voice tool`。
- [ ] 使用生产离屏入口分别设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_LANGUAGE=zh-Hans` 与 `en`，两种语言均生成浅色、深色的适用页面集合；重点检查连接页恢复操作、输入工具卡与四个步骤、语音测试确认卡、输入框、增益滑块和底部导航全部可见。
- [ ] 逐页检查普通用户可见的标题、正文、状态卡、按钮、提示、错误信息和帮助文案，只描述当前状态、实际影响与下一步操作，不出现“待真机验证”“需要兼容性验收”“待回归”“自动化/CI 已通过”“候选实现”“开发中”“验证中”等研发、测试或内部验收用语。
- [ ] 未完成真实环境验收的能力未显示为支持、推荐或可正常使用；已经公开但当前不可用的能力只显示用户能理解的“暂不支持”“暂时无法使用”及可执行的替代方案或后续操作，技术原因码和验收状态仅保留在日志、复制诊断和内部验证证据中。
- [ ] 按下方生产页面与场景清单检查本次适用的完整或定向集合，确认没有遗漏、重复或多余文件。正常状态页面在 `1020 × 772` 下完整可见；右栏视觉内容统一下移，底部提示、继续按钮和主要修复动作不得裁切。
- [ ] 所有中文文字最终显示字号不低于 12pt。
- [ ] 浅色、深色、降低透明度和增强对比度下内容可读。
- [ ] 语音测试输入框在浅色、深色下的占位符字体、光标和正文起点对齐，中文字号不低于 12pt。
- [ ] 豆包、微信与 Vokie 分支分别显示匹配当前外观的真实截图；五个工具都显示完整的步骤 1/2/3/4，并显示匹配当前外观的系统 Fn 与微信 App Fn 冲突截图。
- [ ] 五个工具的第 3 项均显示“去除系统 Fn 占用”、当前公开状态和打开键盘设置按钮；截图模式只渲染状态，不修改系统设置。
- [ ] 输入工具页不显示快捷键配置来源、学习路径或 Command/Option 选择；固定排序和卡片说明在浅色/深色下完整可读。
- [ ] 浅色模式左右均为浅色体系；深色模式左右均为深色体系，不出现黑白分栏。
- [ ] 键盘 Tab、Return、Space 和 VoiceOver 可到达选择卡、权限按钮、返回与继续。
- [ ] 完成后依次打开连接与语音、按键映射、统计、设置，确认权限与隐私、通用、诊断与日志区、页头、主要控件和滚动正常。
- [ ] RC003 普通 `STREAM_START → AUDIO → STREAM_STOP` 语音基线正常。
- [ ] 设置页可见、设置窗口关闭和 Onboarding 语音测试页三种状态的 30 秒连续语音 CPU 已记录，且不再持续接近占满一个核心。
- [ ] 普通按键默认动作、自定义快捷键、双击、长按和多遥控器行为未变化。
- [ ] 菜单栏状态、Sparkle 更新和“启动时自动打开主面板”在已完成用户中保持原行为。

### 英文文案回归（2026-10-03）

- [ ] 英文使用 `voice button`、`voice typing app`、`Up Arrow` 和 `Single Press`；实体按键操作不写成鼠标 click。
- [ ] 按住与按一次两种语音模式分别检查恢复提示。提示引用页面当前操作指引，不强制要求另一种模式。
- [ ] 英文右栏保留原始中文截图，并显示中英选项对照。检查豆包、WeType、Vokie、macOS Fn 和微信快捷键说明的浅色、深色状态。中文页面不增加英文说明。
- [ ] iPhone、Apple Watch 与 Web 首次连接批准弹窗的标题、正文、按钮和校验码辅助功能标签跟随 App 语言。分别检查允许、拒绝、停止等待；确认可信设备保存规则不变。
- [ ] Reflections 的删除当前应用操作显示 `Delete History for This App`；它只删除该应用的历史。单条历史数量显示 `1 entry`，多条显示 `entries`。导出录音的默认文件名跟随 App 语言。
- [ ] macOS 蓝牙与本地网络用途说明覆盖支持的设备；Apple Remote 系统授权说明按系统语言显示。系统权限授权仍需现场检查。

本次改动只修正文案及语言选择。离屏入口使用隔离偏好；其截图和流程自动化不证明真实连接、音频或第三方工具文字上屏成功。

## 生产页面与场景清单

页面以 `Sources/RemoteMic/OnboardingScreenshotRenderer.swift` 的 `pages(for:)` 为来源。执行前从该函数提取步骤和输出名称，按当前 Commit 自动计数并与实际 PNG 文件名集合核对；不能只比较总数。当前页面对应如下，代码增删时同步此表。

| 页面步骤 | 输出文件 |
| --- | --- |
| welcome | `01-welcome.png` |
| remoteAvailability | `02-control-source.png` |
| permissions | `03-permissions.png` |
| remote | `04-remote.png` |
| audio | `05-audio.png` |
| voiceTool | `06-voice-tool.png` |
| voiceTest | `07-voice-test.png` |
| controls | `08-controls.png` |
| complete | `09-complete.png` |

| 矩阵维度 | 适用集合 |
| --- | --- |
| 来源 | 公开包：xiaomi_remote；完整包另含 siri_remote 的 generation_6 / generation_7、chromecast_remote、apple_companion、web_remote；以实际 Package 能力为准；Siri 另需 Installer 收据 |
| 语言 | zh-Hans、en |
| 外观 | light、dark |
| 工具附加状态 | 五种工具、右栏四步、可观察的安装/运行状态、Fn 占用、Vokie partial/failed；只用生产入口支持的状态注入，不能把不支持的注入写为通过 |
| 来源附加状态 | 更多方式折叠/展开、连接恢复、误按语音键、Siri 收据有/无、会员试用完成提示及当前变更影响的状态 |

基础数量为各启用来源的页面数总和 × 语言数 × 外观数。附加状态单独列出并去重，不混入基础数量。完整验证覆盖整张矩阵；定向验证在 PR 列出受影响单元和排除理由，并核对完整清单未改变。逐文件记录格式、像素尺寸、SHA-256、Commit、来源、语言、外观和状态。

规则调整本身不代表重新完成产品验收。下方带日期的截图记录只证明当时 Commit 和环境。

## 用例 9：锁屏离屏截图隐藏入口

1. 保持 Mac 锁屏或不依赖当前屏幕读取权限。
2. 使用生产隐藏入口构建一次 App，并通过 `REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR`、`REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE=light|dark` 生成截图；第 2 页为 `02-control-source.png`，第 6 页为 `06-voice-tool.png`。
3. 公开构建设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_SOURCE=xiaomi_remote`，按生产页面清单生成适用语言和外观集合。
4. 包含 Siri 的截图构建可用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_SIRI_REMOTE_INSTALLED=1|0` 注入收据存在/缺失；可用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_SIRI_REMOTE_TRIAL=1` 渲染非会员临时启用的完成提示；这些值仅用于隔离截图，不写入系统。完整 Package 构建分别设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_CONTROL_SOURCE=xiaomi_remote|siri_remote|chromecast_remote|apple_companion|web_remote`；Apple 来源再用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_APPLE_REMOTE_GENERATION=generation_6|generation_7` 分开生成。按本次构建实际支持的来源、语言和外观生成完整集合，数量由清单推导。
5. 对输入工具页额外覆盖豆包、微信、Typeless、Vokie、其他工具，以及 available/not-installed/unknown；每个工具用 `REMOTE_MIC_ONBOARDING_SCREENSHOT_GUIDE_STEP=0...3` 覆盖右栏四项步骤，Vokie 必须分别生成浅色/深色步骤截图。语音测试页另覆盖 Vokie/Typeless 未运行与运行中状态。
6. 分别覆盖五个输入工具，确认固定排序、单行卡片标题、Fn staged 配置和右栏步骤无裁切。对 Vokie 额外覆盖 `partial`、`failed` 回流提示。
7. 对旧正式配置设置 `REMOTE_MIC_ONBOARDING_SCREENSHOT_VOICE_KEY_MODE=left_command|right_command|right_option`，确认重新运行不会在欢迎或工具选择时立即覆盖；旧 Fn-only 迁移提示不得再被当作现行配置规则。
8. 逐张用图像查看工具检查窗口 chrome、标题、导航、状态卡、右栏、裁切、对比度和中文字号，并在执行前后核对用户正式 Onboarding 进度未变化。
   - 连接失败卡必须完整显示在底部导航上方；重点检查 Chromecast 浅色/深色 `04-remote.png`。
   - 连接失败说明必须只指向当前来源；实体遥控器、Apple 设备和网页版不得互相混写。
   - 实体遥控器按键卡只显示用户可执行的操作，不显示“监听状态”或“按键映射未启用”等内部状态。
9. 不设置截图环境变量正常启动 App，确认不会显示截图入口、额外窗口或调试菜单。

预期结果：锁屏状态仍能从生产 `OnboardingView` 生成全部页面；每张为有效 PNG、像素尺寸有效并记录 SHA-256；浅色和深色分别保持一致视觉体系；公开包与完整包入口严格按编译能力区分；隐藏入口不修改正式偏好，也不影响正常启动。

失败判定：依赖屏幕录制权限、输出设计稿或重绘图、缺少任一页面、左右黑白分栏、正式向导进度变化，或普通用户能在界面中发现截图入口。

当前完整包截图记录（2026-09-23）：使用包含小米遥控器、Siri Remote、Chromecast 遥控器、iPhone / Apple Watch App 与 Web 遥控器入口的生产 `OnboardingView` 隐藏离屏入口，为五个来源分别生成浅色和深色各 9 张，共 90 张。输出目录为 `Screenshots/design-drafts/onboarding-tool-binding-fixes/full-package-90-fixed-20260923`；每张 PNG 均为 `2040 × 1608`，按文件名排序后对逐文件 SHA-256 清单再次计算得到组合 SHA-256 `53982846f8d396a8cb3ad6ff0987c2b43e4c736169bd8d65b6a6fc74c3a96938`。90 张图片已逐张查看窗口 chrome、标题、阶段导航、状态卡、右栏、底部导航、裁切、对比度和中文字号；同时重点复核 Chromecast 浅色/深色 `05-remote.png`、来源专属恢复文案、Apple Watch 状态、Web 二维码内容、权限说明和普通用户页面中的内部测试术语，静态页面检查通过。该记录只证明本次构建的静态布局、外观和文案，不替代 TCC 权限弹窗与恢复、真实遥控器、iPhone / Apple Watch Nearby、Web WSS、MiRemoteV / BlackHole 音频、第三方输入工具快捷键与运行状态，以及松开语音键后文字真实保留在输入框中的现场验收。

当前公开构建增益布局复核记录（2026-09-24）：使用公开能力构建的生产 `OnboardingView` 隐藏离屏入口生成小米遥控器分支浅色/深色各 9 张，共 18 张。输出目录为 `Screenshots/design-drafts/onboarding-tool-binding-fixes/ui-audit-light-2` 与 `ui-audit-dark-2`；每张 PNG 均为 `2040 × 1608`，逐张检查了标题、阶段导航、左侧内容、右栏真实遥控器图片、继续按钮、底部提示、浅深色对比度和中文字号，重点确认语音测试页的输入框、增益说明、滑块、当前 dB 值及底部导航均未裁切；欢迎页中文标题也已调整为自然两行，避免孤立单字。按文件名排序后的 SHA-256 清单组合哈希为 `c169997869333b24884a282c59122c3f0e19e5a6a28f2b64a27516799f5e50f3`。该记录仍不替代真实遥控器、权限、音频和第三方输入工具文字上屏验收。

历史候选截图记录（2026-08-31，非当前门禁结果）：实体遥控器浅色/深色各 9 张，iPhone App 浅色/深色各 10 张，网页版浅色/深色各 10 张，共 58 张；均由生产 `OnboardingView` 离屏入口生成并逐张查看。设置页另生成中文/英文、浅色/深色各 7 张（`800 × 650` 离屏压力尺寸），用于检查主设置页布局和按键模式相关内容。截图均保存在当时的本地证据目录，不代表当前 PR 已完成这些检查。

历史候选自动化记录（2026-08-31，非当前门禁结果）：Onboarding/虚拟音频定向测试 63 项通过，完整 `swift test` 435 项、37 个 suite 通过，`scripts/test.sh` 44 项项目自检通过，`swift build -c release` 通过。这里保留的是当时的原始命令记录；当前在 macOS 本地重跑 SwiftPM 命令必须添加 `--disable-keychain`。现有 deprecated API warning 不属于当次改动引入的失败。

## 通用回归补充

以下项目用于后续 Onboarding 修改的逐项回归，不属于普通用户界面文案：

- [ ] 右栏四个步骤初始均未选中；逐项点击 1、2、3、4 后继续按钮才恢复可用，不能因为默认高亮而跳过首次点击。
- [ ] 步骤门禁阻止继续时，页面明确提示用户查看右栏；提示只说明下一步动作，不显示“待验证”“测试中”“CI”或其他内部状态。
- [ ] 逐一点击返回、继续、卡片、权限入口、刷新、重试、展开/收起和底部提示相关控件，确认删除某段文案没有连带删除连接、音频选择或真实门禁能力。
- [ ] Secure Input 场景只验证公开布尔状态、实体遥控器普通按键等待和重新检测；页面与日志均不出现 PID、前台进程、IORegistry 或第三方私有状态。
- [ ] 离屏截图逐页检查窗口、标题、右栏、底部区域、按钮、对比度、中文字号和裁切；同时记录截图不能替代权限、真实硬件、音频、第三方工具和最终文字上屏验收。
- [ ] 本地交付验证 `SayAll.app` 的 Bundle 结构、资源、签名和启动行为，不把 SwiftPM 的 `RemoteMic` 可执行文件直接作为用户测试包。

## 日志收集

可从“文件 → 打开日志所在文件夹”直接打开目录，也可右键菜单栏图标选择“显示日志”，然后提供 `runtime.log`。即使 Onboarding 未完成，文件菜单入口也必须可用。记录问题发生时间、macOS 版本、所选语音工具、所选控制方式、权限状态、连接状态和实际结果。

日志中的“收到事件”“解码成功”或“入队成功”都不能单独证明向导通过；必须同时核对页面实时状态和最终文字结果。不要提供音频、输入框文字、蓝牙地址、外设标识或其他个人信息。

每次进入页面应有 `ONBOARDING STEP entered=<step>`，用于确认失败发生在哪个步骤；遥控器页还应结合 `BLE ...`、`VOICE FN MAPPING ...`、`HID PERMISSIONS ...` 和 `HID START ...` 的事件顺序判断，不能只看最终一个状态。

权限页返回应依次出现 `reason=user_back` 和 `auto_route_suppressed=true`。语音页应使用 `ONBOARDING TRANSCRIPT_TARGET` 核对输入框是否挂载、窗口是否为 key、是否为 first responder，并使用同一个 `attempt` 的 `ONBOARDING VOICE_ATTEMPT started/terminal` 判断最终结果；`boundary=external_tool_internal_state_unavailable` 表示无线麦自身音频与输入目标均可观察，但不能读取第三方语音工具内部识别或提交状态。

## 自动化、代理实测与用户实测边界

- 自动化覆盖步骤顺序、阶段、所有门禁、流程版本、当前位置、语音工具、控制来源、Binding 的 staged/verified/rollback、完成和重新运行持久化。
- 自动化覆盖公开构建只显示小米遥控器，以及编译宏对应的 Siri、Chromecast、Apple 设备 App、Web 入口；私有 Package 本身是否真实可连接仍需对应构建与现场验收。
- 自动化覆盖实体遥控器/Apple 设备 App/网页版的权限差异、普通按键来源和语音来源接线；它不能证明真实 Watch/iPhone Nearby、WSS、二维码、首次批准或手机麦克风可用。
- 自动化覆盖 Apple 设备 App/网页版在音频未持续运行但设备仍已选择时可进入语音测试和完成页，同时保证实体遥控器仍要求持续 Ready、所有路径在设备缺失时仍失败；真实手机/手表语音按需建链和释放仍需现场验收。
- 自动化覆盖旧 Build 和 Sparkle 启动证据迁移、全新安装重复启动、跨 Build 更新、中途续接和主动重新运行；真实 Sparkle 升级后的偏好与窗口结果仍需执行用例 0。
- 自动化覆盖“已收到 HID 按键但 BLE 未连接”只请求一次恢复，以及 `reconnect()` 在 bridge 尚未创建时进入蓝牙启动分支；它不是真实 CoreBluetooth 回调或 Sparkle 升级验收。
- 自动化覆盖固定 Fn staged Binding、来源转换、Fn 点按和 Chromecast 原生 toggle；它不能证明第三方工具真实接受注入的按键，也不能替代 iPhone/Watch/Web 对实际 hold/toggle 模式的协议上报。
- 自动化覆盖“语音 bridge Ready 或生产 HID 普通按键任一成立即可识别实体控制”，但普通键盘和系统蓝牙列表状态均不在该证据链中；它不能替代 RC001 / RC003 真实时序和后续语音基线。
- 自动化覆盖从系统蓝牙设置返回时刷新 discovery，以及多个 HID service 部分成功时按 Location ID 只监听安全设备；它不能替代真实新配对、双遥控器、电源键锁屏保护和 IOHID 热插拔验收。
- 自动化覆盖遥控器页回到前台时同时刷新 BLE/HID、音频页回到前台重新枚举设备、HID 错误与重试入口接线，以及完成页对当前权限/BLE/音频的最终重验；它不能模拟真实系统设置、驱动安装和硬件时序。
- 编译与单元测试不能证明真实系统权限、RC003、苹果遥控器第 6 / 7 代、Chromecast、iPhone/Watch Nearby、手机 Safari 网页版、MiRemoteV 2ch、BlackHole 2ch、豆包、微信输入法、Typeless、Vokie 或文字上屏。自动化可以证明两种受支持虚拟设备通过、普通输出被拒绝，但第三方工具真实写入仍需现场验收。
- 本次 Onboarding 策略固定使用 Fn；第三方工具内部快捷键、模式、麦克风和冲突状态仍不可观察，必须由用户确认并通过真实文字上屏。
- 代理可在有图形会话时检查页面布局和基础交互，但不能替代用户机器上的权限历史、真实硬件和第三方 App 配置。
- 代理可在锁屏状态通过隐藏离屏入口验证生产页面的静态布局和浅色/深色外观；这不证明权限弹窗、遥控器、驱动或文字上屏链路真实通过。
- 用例 2～8 的真实设备与第三方工具结果全部通过后，才能把功能状态改为“已完成”。

## Issue #106 回归：映射关闭时返回键

对已有实体遥控器配置关闭“自定义按键功能”，在普通文本框按返回键。预期只读取并执行返回键退格动作，方向、音量等其它按键仍由 macOS 系统托管；没有输入监控或辅助功能权限时应显示权限提示。

## 2026-10-18 产品名称文案核对

- 范围：中文产品名改为“无线麦 SayAll”，英文产品名为 `SayAll`，中文分享文案为“无线麦 SayAll App”。同步权限提示和用户复制的配置说明。
- 分类：纯文案；未修改页面清单、布局、权限请求、连接、语音键、音频、配置命令和持久化。
- 检查：本地化键与格式占位符保持一致；配置说明中的命令、Bundle ID 和历史 App 路径保持原值；公开 SwiftPM 构建通过。
- 截图：生产离屏入口生成中文/英文、浅色/深色共 36 张截图，生产页面清单保持一致；抽查权限、语音测试、输入工具和完成页。截图仅证明静态显示，不表示真实权限或语音输入已验证。
- 真实环境：未执行真实权限、遥控器、音频或第三方输入工具验收。该记录不表示新安装包或发布验收通过。

## 2026-10-18 私有构建交互测试预期修正

- 范围：只修正离屏交互测试；生产页面、权限、连接、语音和持久化不变。
- 原因：接入 Chromecast Package 后，可编译来源包含 Chromecast；产品规范要求向导隐藏该选项。旧测试错误要求点击隐藏控件。
- 回归：确认离屏控件中没有 Chromecast；逐一点击其余可见来源，并核对选择结果。保留来源可见性策略的独立测试。
- 边界：自动化只验证生产视图的控件接线；不代表真实设备或第三方工具验收。

## 完整备份导入的验证边界（2026-10-20）

完整配置备份保留用户选择的语音工具和正式语音触发键。
备份不迁移向导完成状态、临时试用状态或已通过验证的证据。
此改动只扩充备份内容，不改变向导页面、生产清单或通过条件。
自动化检查工具选择往返、旧格式兼容和向导期间保留 Finder 请求。
新 Mac 仍须完成本机权限、连接、真实音频和文字上屏验证。
