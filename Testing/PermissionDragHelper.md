# 权限拖动卡测试手册

> 适用分支：`feat/permission-drag-helper-20261127` 及包含该功能的后续候选。本文只定义权限拖动卡的验证方法和证据；权限门禁、Onboarding 流程和产品行为仍以 [`feature/first-run-onboarding/PRODUCT_SPEC.md`](../feature/first-run-onboarding/PRODUCT_SPEC.md) 与 [`platform-macos.md`](../feature/first-run-onboarding/platform-macos.md) 为准。

## 功能范围

从 Onboarding 权限页或设置页「权限与隐私」打开输入监控、辅助功能时，SayAll 在系统设置权限列表旁显示一个 318 × 108 pt 的非激活置顶拖动卡：

- 卡片显示真实 app bundle 图标和文件名，不使用官网插画或装饰图。
- 输入监控的短列表把卡片放在列表下方，左边缘与列表对齐。
- 辅助功能的长列表把卡片放在系统设置窗口外侧，优先右侧，空间不足时左侧，最后退回当前屏幕安全区。
- 拖动卡拖入真实 bundle URL；拖入后自动检测授权。授权成功后卡片关闭；系统密码或 Touch ID 授权弹窗出现时卡片隐藏，不覆盖系统窗口。
- 找不到系统设置窗口时，卡片停在屏幕安全区并提供「重新打开系统设置」；仍保留点 `+` 手动添加路径。
- 卡片使用 macOS 语义色和系统强调色；浅色、深色、中文、英文均可用。

不改变：权限判定、Onboarding 步骤顺序、继续门禁、蓝牙授权、设备连接、音频、持久化和现有「打开系统设置」按钮。

## 测试前准备

1. 用公开模式构建并打包：`SAYALL_PRIVATE_PLATFORM_MODE=public ./scripts/package-local-test-app.sh`。
2. 测试真实拖动时，优先使用不同 bundle ID 的测试副本，避免重置用户已授权 App 的 TCC：
   - 复制 `dist/SayAll.app` 到仓库外目录。
   - 只修改副本 `Info.plist` 的 `CFBundleIdentifier`，保留文件名 `SayAll.app` 和显示名。
   - 用 ad-hoc 或 Developer ID 重新签名后启动。
3. 确认测试副本的输入监控和辅助功能都未授权；如果系统设置已存在同名行，记录实际行数和 bundle 身份后再测试。
4. 退出其他 `RemoteMic` 实例，避免共享实例锁阻止测试副本启动。
5. 准备浅色和深色系统外观、中文和英文 App 语言、主屏和副屏各一次。
6. 日志目录：`~/Library/Logs/RemoteMic/runtime.log`，只看脱敏的 `PERMISSION_HELPER` 事件。

## 用例 1：Onboarding 输入监控

1. 进入 Onboarding 权限页。
2. 点击「输入监控」整行。预期：系统设置打开输入监控，拖动卡在权限列表下方出现。
3. 检查卡片：真实 app 图标 56 pt、文件名与 bundle 一致、产品名副标题、提示、虚线边框、「拖我」和关闭按钮完整；左边缘与列表对齐，顶部与列表底部留约 18 pt；不覆盖权限行和 `+ / −`。
4. 按住卡片拖入列表。预期：出现 40 × 40 图标加文件名的小拖影；松手到列表后显示「已拖入，正在检查权限…」，随后显示「还在等待系统授权」。
5. 系统密码或 Touch ID 弹窗出现。预期：拖动卡立即隐藏，不覆盖弹窗。
6. 完成系统授权。预期：卡片显示「已添加」后自动关闭；权限页输入监控变为已授权；继续门禁按原逻辑更新。
7. 关闭系统设置再打开一次权限行。预期：输入监控已授权时不显示卡片，日志记录 `action=skipped result=already_granted`。

## 用例 2：Onboarding 辅助功能

1. 在权限页点击「辅助功能（新名称：设备控制和数据访问）」。
2. 预期：系统设置打开长列表；卡片停靠在系统设置窗口外侧，和列表顶部附近对齐；不覆盖任何权限行、开关或 `+ / −`。
3. 检查右侧空间不足时卡片改用左侧；两侧都不足时退回当前屏幕右下安全区。记录实际使用的 placement。
4. 拖动卡片到列表；系统授权弹窗出现时卡片隐藏；授权完成后卡片关闭，辅助功能行变为已授权。
5. 滚动长列表。预期：卡片不跟随列表滚动覆盖行；窗口移动时卡片在下一个轮询周期跟随，仍在窗口外侧。

## 用例 3：设置页入口

1. 在设置页「通用」→「权限与隐私」找到输入监控和辅助功能行。
2. 点击「打开系统设置」。预期：仍使用现有按钮和文案；对应系统设置与拖动卡出现，日志 `source=settings`。
3. 已授权行仍可打开系统设置；不显示拖动卡。
4. 关闭卡片后再次点击同一行。预期：卡片重新出现；不写设置、不改变当前页面。

## 用例 4：系统授权弹窗

1. 从拖动卡把 app 拖入系统设置列表。
2. 系统密码/Touch ID 弹窗出现时，确认拖动卡已隐藏，弹窗完整可操作，不被卡片遮挡。
3. 点「取消」。预期：弹窗消失后拖动卡重新出现，状态为等待授权；可以重试或关闭。
4. 再次拖入并完成授权。预期：卡片不会在弹窗期间回到最上层；授权完成后关闭。

## 用例 5：找不到系统设置窗口

1. 点击权限行后立即关闭系统设置窗口，或阻止系统设置出现在当前屏幕。
2. 等待约 3 秒。预期：卡片停在当前屏幕右下安全区（避开 Dock），状态显示「重新打开系统设置」，同时保留「拖入列表，或点 + 添加」提示。
3. 点「重新打开系统设置」。预期：系统设置重新打开；窗口出现后卡片回到列表旁/窗口外侧，按钮消失，状态恢复可用。
4. 关闭系统设置窗口。预期：卡片关闭，日志记录 `reason=settings_window_closed`。

## 用例 6：拖动失败与重试

1. 从卡片拖到桌面或拖出系统设置窗口后松手。
2. 预期：卡片留在原位，状态显示「拖动失败，请点 + 添加」；不静默消失。
3. 再次拖动到列表。预期：状态先回到可拖动，成功后进入检查中；失败路径不改变权限状态。

## 用例 7：关闭与键盘

1. 点卡片关闭按钮。预期：卡片关闭，日志 `reason=close_button`；系统设置和权限状态不变。
2. App 处于前台时按 Esc。预期：卡片关闭，日志 `reason=escape`。
3. 系统设置在前台时按 Esc。预期：以系统设置行为为准；卡片关闭按钮始终可用，不能把 Esc 当作唯一退出路径。
4. 关闭系统设置窗口。预期：拖动卡在下一次轮询后关闭。

## 用例 8：外观、语言与多屏

1. 浅色、深色各执行一次输入监控和辅助功能用例。预期：卡片背景、文字、虚线、强调色和状态色随系统语义色变化；系统强调色变化后重新打开，卡片使用新的强调色。
2. 中文、英文各执行一次。预期：英文提示、等待、失败和重新打开文案不被截断；中文不小于 12 pt；文件名仍为真实 bundle 文件名。
3. 主屏、副屏各打开一次系统设置。预期：卡片出现在系统设置所在屏幕，不跨屏漂移；屏幕边缘和 Dock 安全区内可见。
4. 移动系统设置窗口后等待一个轮询周期。预期：卡片重新贴到列表下方或窗口外侧。

## 用例 9：签名与 TCC 变化

1. 对测试副本重新签名或改变 bundle ID。预期：旧 TCC 条目不生效；权限页显示未授权；拖动卡仍显示测试副本的真实文件名和图标。
2. 从系统设置移除测试副本后重新授权。预期：拖动卡不复活旧状态；授权成功后关闭并按新状态刷新。
3. 正式签名升级的权限连续性按 `Testing/MacPreviewPermissionContinuity.md` 和发布流程单独验证，不用 ad-hoc 副本代替。

## 失败判定

- 权限行点击后不出现拖动卡，或卡片覆盖权限行、开关、`+ / −`。
- 卡片显示的不是真实 app 图标或 bundle 文件名，或拖影使用 512 px 大图。
- 系统密码/Touch ID 弹窗出现时卡片仍在最上层，遮挡弹窗。
- 拖入后不显示检查/等待状态，或权限已授权后卡片不关闭。
- 找不到系统设置窗口时没有安全区回退或「重新打开系统设置」。
- 已授权后仍弹出拖动卡，或卡片写入设置、改变向导步骤/继续门禁。
- 关闭按钮、Esc（App 在前台时）、系统设置关闭路径无法退出，或卡片重复叠加。
- 中文小于 12 pt、英文被截断、浅色/深色不可读，或卡片在副屏/Dock 外。
- 日志包含路径、文件名、用户内容、窗口坐标或第三方 App 私有状态。

## 日志

成功路径至少包含：

```text
PERMISSION_HELPER action=requested pane=input_monitoring source=onboarding
PERMISSION_HELPER action=shown pane=input_monitoring source=onboarding placement=below_list
PERMISSION_HELPER action=drag_started pane=input_monitoring source=onboarding
PERMISSION_HELPER action=drag_ended result=accepted pane=input_monitoring source=onboarding
PERMISSION_HELPER action=hidden reason=system_modal pane=input_monitoring source=onboarding
PERMISSION_HELPER action=shown reason=system_modal_cleared pane=input_monitoring source=onboarding
PERMISSION_HELPER action=permission_granted pane=input_monitoring source=onboarding
PERMISSION_HELPER action=closed reason=granted pane=input_monitoring source=onboarding
```

失败和恢复路径记录 `drag_failed`、`skipped result=already_granted`、`closed reason=settings_window_closed|close_button|escape|replaced`。日志不记录 app 路径、实际窗口坐标、权限列表内容或用户输入。

## 自动化、代理实测与真实验收边界

- 自动化覆盖：窗口/屏幕坐标的纯布局计算（列表下方、左右外侧、安全区、面板 6 pt 内边距）、来源和 pane 日志 token、真实 bundle/图标/NSDraggingItem 接线、双语文案、系统设置 owner 名称和主题色/材质使用。
- 代理实测：真实系统设置窗口的列表位置、卡片跟随、拖动、系统授权弹窗隐藏、关闭和 fallback；使用测试 bundle 副本，不修改正式 App 的 TCC。
- 真实用户验收：正式签名 App 的首次授权、Touch ID/密码授权后自动关闭、真实拖动到最终生产 App 行、多显示器、浅色/深色、中文/英文、系统设置关闭/重开和升级后的权限连续性。
- 模拟窗口、离屏截图、单元测试和构建不能替代真实系统授权和真实拖动。

## 本轮结果（2026-11-27）

- 公开模式 `swift build --disable-keychain` 和完整 `swift test --disable-keychain --no-parallel`：通过（1716 项 / 125 套件）；`PermissionDragHelperTests` 8 项、`LocalizationTests`、`OnboardingFlowTests`、`SettingsPageRegressionTests` 通过。
- 真实系统设置验证（独立 bundle ID 测试副本、Build 449、副屏）：输入监控列表下方卡、辅助功能左侧长列表卡、列表对齐与滚动跟随、浅色/深色、中文/英文、拖动拖影、系统授权弹窗出现时隐藏并在取消后恢复、「还在等待系统授权」、关闭按钮关闭。
- 本轮未执行真实验收：正式签名 App 的首次真实授权和 Touch ID/密码完成后的 `closed reason=granted`；`source=settings` 真实设置页入口（当前由 source token 单元测试覆盖）；fallback 安全区重开（当前由布局单元测试覆盖）；主屏系统设置窗口矩阵。
- 截图和哈希见 PR 证据；测试副本不改变正式 App 的 TCC。
