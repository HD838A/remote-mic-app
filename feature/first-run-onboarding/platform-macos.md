# Onboarding macOS 平台适配规范

本文把 [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) 的跨平台产品能力映射到当前 macOS 实现。跨平台产品不变量以产品规范为准；本文只规定 macOS 的具体适配和验收边界。

## 当前平台映射

| 产品能力 | macOS 实现 |
| --- | --- |
| 主控制来源 | 小米蓝牙遥控器 2 / 2 Pro；私有 Package 存在时增加苹果遥控器第 6 / 7 代与 Chromecast 语音遥控器 |
| 替代控制来源 | 仅 `SAYALL_MAC_REMOTE_ENABLED` 构建显示 iPhone / Apple Watch App 与手机网页版 |
| 必要权限 | 蓝牙、输入监控、辅助功能；具体分支仍以生产能力要求为准 |
| 语音工具 | 豆包输入法、微信输入法、Vokie、Typeless、其他支持语音输入的工具 |
| Onboarding 语音键 | 本次 staged 配置统一固定为 Fn；真实语音文字通过后才提交 |
| 音频路线 | SayAll 输出到受支持的虚拟音频设备，第三方工具把同一设备选择为麦克风 |
| 输入目标 | 原生 AppKit 文本编辑器必须成为当前 key window 的 first responder |
| 完成证据 | 当前来源连接、普通按键、语音开始、真实样本、音频投递、语音结束、第三方文字写入和三个不同普通按键 |

## macOS 特有要求

### 权限

- 苹果遥控器服务默认关闭。仅在用户选择苹果遥控器或主动启用时开启。
- App 启动、设备发现、回到前台和自动重试不得请求 Siri helper 安装或音频交互授权。
- 取消授权后保存等待状态，重启不得自动准备音频或再弹窗。
- 用户点击重新连接、语音失败恢复或遥控器卡片内的重试后，才可重试授权。
- 已主动启用的选择可以保留；已有组件和同意记录满足条件时，后台静默恢复。

- 不得在准备阶段为判断设备状态而提前启动会触发权限的扫描。
- 蓝牙、输入监控和辅助功能卡在已授权后仍可打开对应系统设置。
- TCC 权限变化、需要重启和 App 签名身份变化必须在诊断与测试中区分。
- 正式签名升级权限连续性不能由 ad-hoc 构建代替验证。

### 输入法与语音键

- 输入工具保持豆包、微信、Vokie、Typeless、其他的相对顺序；豆包、Vokie 和其他始终显示，微信与 Typeless 仅在公开 Input Sources / Bundle 查询确认已安装时显示。安装状态刷新只能增删对应卡片，不得改变其余卡片的相对顺序。
- 控制设备卡片中的设备名称必须保持单行；空间不足时优先调整卡片内部布局，不得把型号名称拆成两行。
- Onboarding 不展示配置来源、快捷键学习或 Command/Option 选择，所有工具的本次 staged 语音键固定为 Fn。
- 工具页右栏对当前可见工具显示对应四项步骤：豆包、微信和 Vokie 的工具步骤使用按外观切换的真实截图，Typeless 与其他工具使用简短操作说明；第 3 项统一显示“去除系统 Fn 占用”的 macOS 键盘设置截图、公开状态和打开设置操作。
- Vokie 卡片使用“智能整理，不占用输入法，实时显示文字”的简短介绍，并提供 `https://vokie.com` 官方入口。
- 英文卡片名称固定为 `Doubao`、`WeType`、`Vokie`、`Typeless`、`Other Voice App`；不得显示 `Doubao Input Method`、`WeChat Input Method` 或 `Another Voice Tool`。
- 选择工具或主动重跑 Onboarding 不得立即改写正式 `VoiceKeyMode`、Fn 点按或 Chromecast 模式。
- 配对计划只创建 staged Binding；真实文字测试通过后才提交 verified Binding，失败、返回或退出时恢复原配置。
- 豆包和微信只能通过公开 Text Input Sources API 按精确 Input Source ID 选择；不得按显示名称模糊匹配。Onboarding 选择工具时只观察当前输入源，不自动启用或切换；用户明确点击后才执行一次切换，避免 Radio 选择触发系统确认或设置界面。
- Typeless、Vokie 和其他独立工具不执行系统输入源切换。
- 进入 Typeless 或 Vokie 的语音测试页时，必须通过公开 Bundle ID/URL Scheme 尝试后台启动目标 App，但不得抢走 SayAll 输入框焦点；自动拉起失败、状态未知或目标仍未运行时必须阻止完成并显示“重新打开”，运行后仍保留真实语音文字门禁。
- SayAll 不读取任何第三方工具的私有配置；语音识别键、全局唤起和麦克风只能显示期望值并由用户确认。
- `sayall://launch` 只负责激活与 Vokie 状态回流；received/configured/ready 都不能替代真实语音文字门禁。

### 音频

- 当前 Onboarding 只接受产品明确支持的虚拟音频设备，不允许扬声器或普通输出设备通过。
- SayAll 选择的是音频输出端；豆包、微信、Typeless 或其他工具必须把同一设备选择为麦克风输入端。
- 语音测试输入框页提供 0–24 dB 的增益滑块和面向普通用户的说明；当前值直接复用 `AppSettings.gainDB`，调节后立即作用于后续 PCM，建议先从 6–12 dB 尝试小声或气声。增益变化不得触发音频链路重启，也不得改变 Fn 按下/释放语义。
- 对稳定识别为 MiRemoteV 2ch 或 BlackHole 2ch 的设备，配置和语音开始前必须读取
  input/output scope 主声道的公开 CoreAudio mute/volume 属性；只有明确静音或音量严格低于
  `0.2` 时才自动恢复为未静音和 `1.0`，阈值及以上必须保留。属性不存在时记录为未知并保持兼容，已知异常且
  无法恢复时不得把输出标记为 Ready。实体设备和未知设备不得被修改。
- 实体遥控器与按需音频来源可以有不同的运行时 Ready 语义，但都必须在真实语音测试中完成音频与文字验证。
- 日志分别记录选择、设备存在、实际绑定、调度、播放、中断、pending 和排空状态。

### 控制来源

- 控制来源在欢迎页后的单页中按 Package 门禁显示：公开构建只有小米遥控器；Apple Package 增加苹果遥控器第 6 / 7 代两个入口，Chromecast 和 Mac Remote Package 分别增加对应入口。
- 小米与两代苹果遥控器显著展示；Chromecast、iPhone / Apple Watch 和 Web 收入默认折叠的“更多控制方式”。实体卡片和右栏使用所选设备真实图片。
- 苹果遥控器配对说明不得使用 “Siri Remote” 用户文案，并提示蓝牙名称可能不同，应关注重置后新出现的设备。
- iPhone、Apple Watch 和 Web App 均支持 hold/toggle；旧版未上报实际模式时按 hold 兼容并要求用户确认。
- 实体遥控器必须由生产 BLE/HID 证据确认，macOS 系统蓝牙列表中的“已连接”不能单独通过。
- iPhone 与网页版必须由各自生产会话和事件来源确认，不能由同时在线的实体遥控器代替。
- 语音键仍遵守按下即开始、释放即结束的实时路径；不得加入双击等待或长按阈值。
- 实体遥控器连接页的普通按键检查应明确要求短按圆盘中间确定键或方向键，并明确提示不要按麦克风/语音键。
- 在该页收到当前实体遥控器的 ATVV 语音开始事件时，应显示“刚才按的是语音键”的即时纠正状态；这只改善指导和诊断，不得改变 HID 普通按键通过门槛或语音键实时生命周期。
- 诊断应分别记录该页的语音键触发次数、普通控制键观察次数和最后输入类型，不记录设备身份或按键原始报告。
- 普通按键页进入时清空本次观察集合；小米、苹果、Chromecast、iPhone/Apple Watch 和 Web 路径都只观察新事件，不执行用户已有的单击、双击、长按、宏或内部动作映射。返回、退出或重新运行时不读写这些正式映射。
- 实体遥控器已连接且约 3 秒仍未收到普通按键时，可通过 `IsSecureEventInputEnabled()` 的公开布尔结果显示用户提示。提示只说明系统安全输入可能影响按键，并提供“重新检测”；退出密码/安全键盘应用后会重新应用 HID 设置。不得显示 PID、前台 App、`loginwindow` 或 IORegistry，也不得把该信号作为完成失败原因。

平台实现补充约束：右栏四项指引的初始状态必须全部为空，只有用户逐项点击后才记录为已查看；继续按钮被该门禁阻止时，应在当前页提供查看右栏的明确提示。离屏渲染不得注入默认选中步骤。Secure Input 诊断只消费公开布尔状态，不得扩展为进程或系统内部状态探测，也不得改变普通按键和语音键的实时生命周期。

### UI

- 默认内容尺寸为 `1020 × 772`，完整当前页面和底部导航不依赖页面内部滚动。
- 生产离屏截图入口必须支持通过 `REMOTE_MIC_ONBOARDING_SCREENSHOT_LANGUAGE=zh-Hans|en|system` 明确选择语言；中文与英文都要覆盖浅色和深色，不得把中文截图当作英文布局证据。
- 中文最终显示字号不得小于 12pt。
- 浅色和深色必须保持整个窗口视觉体系一致。
- 主设置“连接”页只保留主要音频设备、增益、状态和刷新操作，不显示豆包兼容专用卡片、BlackHole 获取入口或测试音按钮。
- 用户可见文案必须遵守 [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) 的“用户可见文案必须使用产品语言”不变量；平台实现不得把研发、测试或内部验收状态引入页面。
- macOS 页面或流程变化必须按 [`design-qa.md`](../../design-qa.md) 和 [`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md) 完成检查。

## 实现与测试入口

- 产品行为入口：[`PRODUCT_SPEC.md`](PRODUCT_SPEC.md)
- 现有功能说明：[`README.md`](README.md)
- 代码接入点：[`development.md`](development.md)
- 完整测试手册：[`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md)
- 界面规范：[`design-qa.md`](../../design-qa.md)
- 日志规范：[`LOGGING.md`](../../LOGGING.md)
