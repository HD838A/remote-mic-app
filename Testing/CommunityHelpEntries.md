# 抖音 / 小红书教程入口

适用分支：`feat/community-help-qr-20261126`。候选构建：本地公开测试包 2.0.10（Build 444）。功能进入正式版后按实际版本和 Build 更新本文。

## 范围与不变量

- Onboarding 每一步的页脚左侧显示低强调入口：「配置有问题？扫码关注抖音、小红书，了解教程」。入口不占据右侧主按钮的位置，不改变当前步骤的门禁。
- 设置页「通用」→「重新运行设置向导」行下方显示同一入口。不新增侧栏入口，不改变该行的按钮。
- 两个入口打开同一个浮层。浮层标题「配置有问题？」，说明「扫码关注抖音或小红书，查看设置教程。」，依次显示抖音、小红书二维码和「关闭」按钮。
- 浮层只读展示。它不写 `AppSettings`，不重置向导，不启动蓝牙、权限、音频或输入设备，不请求网络，不上报点击内容。
- 二维码使用 App 内置资源。断网时仍完整显示。中文文字不小于 12pt；浮层宽 500pt，二维码显示尺寸 205pt。
- 中文卡片标题统一为「抖音 · 无线麦 SayAll App」和「小红书 · 无线麦 SayAll App」；英文为「Douyin · SayAll」和「Xiaohongshu · SayAll」。
- 英文版后续可能把第一张卡从抖音换成 X（x.com/getsayall）并保留小红书；当前版本仍为抖音 + 小红书。更换时只替换第一张卡的文案、资源和动作，不改浮层布局。

## 测试前准备

1. 使用 `SAYALL_PRIVATE_PLATFORM_MODE=public ./scripts/package-local-test-app.sh` 构建并启动本地测试包；不要使用旧包。
2. 手机安装抖音和小红书，能使用各自「扫一扫」。扫码验收必须用真实手机，截图解码不能代替。
3. 准备浅色和深色系统外观各一次；中文和英文各一次。
4. Onboarding 使用生产画布 `1020 × 772`。设置页使用生产最小窗口 `1067 × 760`；`1067 × 1100` 只用于离屏截图展示滚动后的入口行，不是生产窗口尺寸。
5. 准备一次断网状态，用于确认二维码不依赖网络。

## 用例 1：Onboarding 入口

1. 打开设置 →「通用」→「重新运行设置向导」，进入欢迎页。
2. 查看页脚左侧。预期：显示二维码图标和完整入口文案；右侧「开始设置」按钮完整可见，按钮位置和尺寸未改变。
3. 点击入口。预期：出现浮层，标题、说明、两张二维码、卡片标题、扫码提示和「关闭」按钮完整；背景内容被遮暗，不能继续操作。
4. 点击遮罩空白处。预期：浮层关闭，焦点回到页脚入口。再次打开后分别验证 Esc 和「关闭」也能关闭。
5. 再打开浮层，保持打开 10 秒。预期：没有网络请求，二维码不消失，不显示加载状态。
6. 关闭浮层后点「开始设置」。预期：按原有门禁进入下一步；入口没有改变向导步骤、权限状态或设备状态。
7. 走到语音工具页并让「继续」处于禁用态。预期：页脚提示和教程入口换行但不重叠，右侧主按钮不被挤出窗口。
8. 在浅色、深色、中文、英文各重复第 2、3、7 步。预期：中文入口不小于 12pt；英文入口最多两行；二维码卡片不裁切。

## 用例 2：设置页入口

1. 打开设置 →「通用」，向下滚动到「重新运行设置向导」。
2. 查看该行下方。预期：显示低强调入口，文字与行标题对齐；「重新运行」按钮仍可用。
3. 点击入口。预期：打开与 Onboarding 相同的浮层。点击遮罩空白处、按 Esc 或「关闭」都能退出。
4. 关闭后确认焦点回到入口；再点「重新运行」按钮。预期：向导仍按原行为启动，入口没有写入任何设置。
5. 在 `1067 × 760` 最小窗口、浅色、深色、中文、英文各检查一次。预期：入口不被裁切，右侧按钮和开关不被挤出窗口。
6. 断开网络后重复第 3 步。预期：二维码仍显示。

## 用例 3：二维码内容

1. 用小红书 App 扫描小红书卡片。预期：进入无线麦 SayAll 的小红书账号或分享页；不能进入无关账号。
2. 用抖音 App 扫描抖音卡片。预期：进入「无线麦 SayAll.App / GetSayAll」抖音账号；不能进入无关账号。
3. 分别保存两张截图并用二维码解码工具核对。预期：小红书码解码为 `http://xhslink.com/m/3d2Bog2tZNP`；抖音码为平台风格码，解码工具可能无法识别，必须以抖音 App 实扫结果为准。
4. 检查二维码中间的头像、平台角标和卡片标题一致。预期：不出现旧产品名、错误账号或二维码服务占位图。

## 用例 4：日志与隐私

1. 打开日志目录，分别触发 Onboarding 入口、设置入口、关闭浮层。
2. 预期日志只包含稳定字段：
   - `COMMUNITY_HELP action=requested source=onboarding`
   - `COMMUNITY_HELP action=presented source=onboarding`
   - `COMMUNITY_HELP action=closed source=onboarding`
   - 设置入口对应 `source=settings`。
3. 预期日志不包含二维码内容、账号 ID、用户内容、网络请求、路径、设备身份或点击坐标。
4. 触发后不做任何扫码。预期：App 不产生二维码识别或网络上传事件。

## 失败判定

- 任一入口缺失、文字被截断、中文小于 12pt，或主按钮/右侧控件被挤出窗口，判定失败。
- 点击入口不出现浮层，或点击遮罩、Esc、与「关闭」任一不能退出，或关闭后焦点不回到入口，判定失败。
- 两个入口打开的不是同一套内容，或卡片标题/账号名/二维码与本文不一致，判定失败。
- 浮层打开时向导步骤、设备连接、权限、音频或任何设置发生变化，判定失败。
- 断网时二维码缺失、显示加载中或请求 sayall.app，判定失败。
- 扫码进入无关账号，或二维码与卡片标题不一致，判定失败。
- 日志包含二维码内容、用户内容、路径、设备身份或网络请求，判定失败。

## 稳定功能回归项

- Onboarding 每一步原有门禁、继续按钮、返回按钮和语音测试路径不变；教程入口不改变 `onboardingStep`。
- 设置页「通用」原有行、开关、语言选择和「重新运行设置向导」按钮不变；入口不写 `AppSettings`。
- 浅色、深色、中文、英文和最小窗口下无裁切、重叠或文字缩小到 12pt 以下。
- 无网络时 App 正常启动，教程入口和二维码不依赖网络。
- `scripts/build-app.sh` 仍把两张二维码资源复制到 App 的 `Contents/Resources/`；`verify-app.sh` 通过。

## 日志收集

- 日志目录：设置页「诊断与日志」→「在 Finder 中显示日志」，或 `~/Library/Logs/RemoteMic/`。
- 只收集 `COMMUNITY_HELP` 相关行、App 版本/Build 和系统外观/语言；不要收集二维码截图中的账号页面内容。
- 运行日志规范见 [`LOGGING.md`](../LOGGING.md)。该功能没有音频、设备或第三方 App 私有状态，因此不记录这些上下文。

## 自动化与验证边界

自动化覆盖：

- `CommunityHelpSheetTests`：两张二维码资源存在且为 512 × 512；两个入口来源的日志 token 稳定；Onboarding、设置页和 `build-app.sh` 的接线与资源复制存在。
- `LocalizationTests.communityHelpCopyUsesUnifiedProductNaming`：中英文入口、标题、说明、卡片标题和扫码提示完整，中文不使用 `SayAll.App` 或「无线麦 App」。
- `OnboardingFlowTests.offscreenOnboardingRegistersAndDrivesEveryInteractiveControl`：欢迎页新增 `community-help` 探针，入口动作已注册并可驱动。
- `SettingsPageRegressionTests`、`OnboardingFlowTests`：既有设置页和向导结构回归。

真实环境边界：

- 离屏截图只证明静态布局、文案和二维码位图，不证明真实鼠标点击、点击遮罩关闭、Esc 关闭、焦点恢复、断网状态或真实扫码。
- 真实抖音/小红书扫码必须由测试者用手机完成。小红书码已用 Vision 解码为 `http://xhslink.com/m/3d2Bog2tZNP`；抖音码是平台风格码，Vision 不能解码，不能据此判定失败或通过。
- 设置页真实窗口内容区为 `1067 × 772`；真实窗口 PNG 含窗口阴影，因此像素尺寸更大。`1067 × 1100` 只用于展示滚动后的入口行，不是生产窗口验收。
- 本功能不涉及蓝牙、音频、HID、系统权限或第三方 App 私有数据，因此不需要遥控器、音频或文字上屏真机验收。

## 结果（2026-11-26）

- 公开模式 `swift build --disable-keychain` 通过；本地公开测试包构建 444 和 445（点击遮罩关闭浮层）通过 `verify-app.sh`。
- 定向测试 232 项通过：`CommunityHelpSheetTests`、`LocalizationTests`、`OnboardingFlowTests`、`SettingsPageRegressionTests`。
- 完整公开测试（`swift test --disable-keychain --no-parallel`）1705 项 / 124 个 suite 通过；本机并行运行在 `KeyboardEventSuppressor` 实时事件回调处收到 SIGSEGV（`swiftpm-testing-helper`），栈不包含本次 UI 变更文件，PR 保留该验证边界。
- 真实窗口（中文浅色）：Onboarding 欢迎页入口可见，点击后浮层完整显示；点击遮罩空白处、按 Esc、点「关闭」均可退出。设置页「通用」向导行下方入口可见，点击后同一浮层完整显示；点击遮罩空白处可退出。
- 真实窗口（中文深色）：设置页入口和浮层完整显示，二维码保持可读；点击遮罩关闭与浅色共用同一实现。
- 生产离屏截图：Onboarding 欢迎页中文/英文 × 浅色/深色各一张，均为 PNG、2040 × 1600；设置页关于页中文/英文 × 浅色/深色各一张，均为 PNG、2134 × 2200（画布 1067 × 1100，仅用于展示入口行）。
- 小红书码解码通过；抖音码需真实抖音 App 实扫，尚未完成。真实手机扫码、英文真实窗口逐项点击和断网状态仍待现场验收。

## 截图证据

图片字节保存在仓库外持久目录：`/Users/andy/Develop/Src/AISrc/design-artifacts/sayall-community-entry-20261126/`。

| 文件 | 场景 | 格式/尺寸 | SHA-256 |
| --- | --- | --- | --- |
| `onboarding-zh-Hans-light/01-welcome.png` | Onboarding 中文浅色 | PNG 2040 × 1600 | `356b931c2256f77caeda6f3862c690881a556d7e35b1f8fe62b8541238d3523a` |
| `onboarding-zh-Hans-dark/01-welcome.png` | Onboarding 中文深色 | PNG 2040 × 1600 | `f120a228b90418274169351d8b75321c7b3c53e5a16428032d7853862fa21341` |
| `onboarding-en-light/01-welcome.png` | Onboarding 英文浅色 | PNG 2040 × 1600 | `a65aa7d816673d408733cf7c265068238bb7b5cd35bc4b88201170a759f9d900` |
| `onboarding-en-dark/01-welcome.png` | Onboarding 英文深色 | PNG 2040 × 1600 | `2fa84e67651dfb170f1ef4a32d5f3f5abc3a40606f9e6fa82f0dc92738e0b22d` |
| `settings-about-zh-Hans-light/about-1067x1100.png` | 设置页中文浅色（离屏） | PNG 2134 × 2200 | `1325617dcb848cdb9d7dd895dd34d058dc270122472b7f1bc92e9730e15c2701` |
| `settings-about-zh-Hans-dark/about-1067x1100.png` | 设置页中文深色（离屏） | PNG 2134 × 2200 | `04d452d8d8c75f1b9dc5ffd8a69e56e2d31249f89bd2ed05c6d509c172b7aaa0` |
| `settings-about-en-light/about-1067x1100.png` | 设置页英文浅色（离屏） | PNG 2134 × 2200 | `7fb0744dc2d85f97c13b12c724db7a66f7395679f68f2ec32cf64bb46e406378` |
| `settings-about-en-dark/about-1067x1100.png` | 设置页英文深色（离屏） | PNG 2134 × 2200 | `52578c2bdd9b8b310a1f383aecc0c89e46ff51e0ce67db1dbd8df10de52cac5d` |
| `evidence/onboarding-help-overlay-real-window.png` | Onboarding + 浮层 中文浅色（真实窗口，点击遮罩关闭版本） | PNG 2226 × 1636 | `bd0e104785e481682493d1e87c7e3bb9f3007af19fce6d263d553766f0d4a355` |
| `evidence/settings-entry-real-window.png` | 设置页入口 中文浅色（真实窗口） | PNG 2134 × 1120 | `7d24a81dc43469de260fd1313ff9a8f2d745ecea0ef36bb813e44a7cdb635d32` |
| `evidence/settings-help-overlay-real-window.png` | 设置页 + 浮层 中文浅色（真实窗口，点击遮罩关闭版本） | PNG 2358 × 1768 | `094040746852d03a4ee863f65e05bfd363dc182f561c6aa33079faef708825d5` |
| `evidence/settings-help-overlay-dark-real-window.png` | 设置页 + 浮层 中文深色（真实窗口，点击遮罩关闭版本） | PNG 2226 × 1636 | `62049cbc5170d3a5b25bb52a4d4a4b05686d3a399ac0a4c730e28b8a05cac280` |

内置二维码资源：

| 文件 | 格式/尺寸 | SHA-256 |
| --- | --- | --- |
| `Resources/community-help-douyin-qr.png` | PNG 512 × 512 | `a9b8f5579c03a99d15cda8cf0ca29c36e3cea6677d98e9fc91560fa499b1023d` |
| `Resources/community-help-xiaohongshu-qr.png` | PNG 512 × 512 | `83265db663b82ec3f993f321886f8f1cd67f14f4faaac50536ec11ce8a6a4ed6` |

二维码原始素材来自私有官网仓库 `sayall-private-platform/apps/official-sites/sayall-app`：

- `public/assets/douyin-sayall.jpg`，1125 × 1680，SHA-256 `bc9c8143e0f4578857952afe5eec832cc18fa3dd17d9b7d6b1899dbbd9f4f2b2`。
- `public/assets/xhs-sayall.jpg`，987 × 1347，SHA-256 `15304a2d715eef0606e07fffdbe19e9f729d91c327adc1227cc5af3cb825abe3`。
