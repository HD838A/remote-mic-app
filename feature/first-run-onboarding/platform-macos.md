# Onboarding macOS 平台适配规范

本文把 [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) 的跨平台产品能力映射到当前 macOS 实现。跨平台产品不变量以产品规范为准；本文只规定 macOS 的具体适配和验收边界。

## 当前平台映射

| 产品能力 | macOS 实现 |
| --- | --- |
| 主控制来源 | 小米蓝牙遥控器 2 / 2 Pro；私有 Package 存在时增加 Siri Remote 与 Chromecast 语音遥控器 |
| 替代控制来源 | 仅 `SAYALL_MAC_REMOTE_ENABLED` 构建显示 iPhone / Apple Watch App 与手机网页版 |
| 必要权限 | 蓝牙、输入监控、辅助功能；具体分支仍以生产能力要求为准 |
| 语音工具 | 豆包输入法、微信输入法、Typeless、Vokie、腾讯 ChatterFly、其他支持语音输入的工具 |
| Onboarding 语音键 | 按工具 Profile 或用户学习 Binding 配置；Fn 只是稳定兜底，不是唯一策略 |
| 音频路线 | SayAll 输出到受支持的虚拟音频设备，第三方工具把同一设备选择为麦克风 |
| 输入目标 | 原生 AppKit 文本编辑器必须成为当前 key window 的 first responder |
| 完成证据 | 当前来源连接、普通按键、语音开始、真实样本、音频投递、语音结束、第三方文字写入和三个不同普通按键 |

## macOS 特有要求

### 权限

- 不得在准备阶段为判断设备状态而提前启动会触发权限的扫描。
- 蓝牙、输入监控和辅助功能卡在已授权后仍可打开对应系统设置。
- TCC 权限变化、需要重启和 App 签名身份变化必须在诊断与测试中区分。
- 正式签名升级权限连续性不能由 ad-hoc 构建代替验证。

### 输入法与语音键

- 豆包、微信默认 hold 为 Fn、toggle 为右 Command；Typeless、Vokie、ChatterFly 已知 toggle 默认键为 Fn。Vokie 与 ChatterFly 的 hold 默认键未确认前不得自动生成 hold 默认方案。
- 默认快捷键只进入“使用推荐配置”快速路径；用户声明修改过快捷键时，权限完成后通过 `ShortcutCaptureMonitor` 学习当前快捷键和 hold/toggle 语义。
- 选择工具或主动重跑 Onboarding 不得立即改写正式 `VoiceKeyMode`、Fn 点按或 Chromecast 模式。
- 配对计划只创建 staged Binding；真实文字测试通过后才提交 verified Binding，失败、返回或退出时恢复原配置。
- 当前可学习并注入的语音键限于 Fn、左/右 Command 与右 Option；不能表达的组合必须明确提示，不得静默降级。
- 豆包和微信只能通过公开 Text Input Sources API 按精确 Input Source ID 选择；不得按显示名称模糊匹配。Onboarding 选择工具时只观察当前输入源，不自动启用或切换；用户明确点击后才执行一次切换，避免 Radio 选择触发系统确认或设置界面。
- Typeless、Vokie、ChatterFly 和其他独立工具不执行系统输入源切换。
- 进入 Typeless 或 Vokie 的语音测试页时，必须通过公开 Bundle ID/URL Scheme 尝试后台启动目标 App，但不得抢走 SayAll 输入框焦点；自动拉起失败、状态未知或目标仍未运行时必须阻止完成并显示“重新打开”，运行后仍保留真实语音文字门禁。
- SayAll 不读取任何第三方工具的私有配置；语音识别键、全局唤起和麦克风只能显示期望值并由用户确认。
- `sayall://launch` 只负责激活与 Vokie 状态回流；received/configured/ready 都不能替代真实语音文字门禁。

### 音频

- 当前 Onboarding 只接受产品明确支持的虚拟音频设备，不允许扬声器或普通输出设备通过。
- SayAll 选择的是音频输出端；豆包、微信、Typeless 或其他工具必须把同一设备选择为麦克风输入端。
- 对稳定识别为 MiRemoteV 2ch 或 BlackHole 2ch 的设备，配置和语音开始前必须读取
  input/output scope 主声道的公开 CoreAudio mute/volume 属性；只有明确静音或音量严格低于
  `0.2` 时才自动恢复为未静音和 `1.0`，阈值及以上必须保留。属性不存在时记录为未知并保持兼容，已知异常且
  无法恢复时不得把输出标记为 Ready。实体设备和未知设备不得被修改。
- 实体遥控器与按需音频来源可以有不同的运行时 Ready 语义，但都必须在真实语音测试中完成音频与文字验证。
- 日志分别记录选择、设备存在、实际绑定、调度、播放、中断、pending 和排空状态。

### 控制来源

- 控制来源在单页中按 Package 门禁显示：公开构建只有小米遥控器；Siri、Chromecast 和 Mac Remote Package 分别增加对应入口。
- iPhone、Apple Watch 和 Web App 均支持 hold/toggle；旧版未上报实际模式时按 hold 兼容并要求用户确认。
- 实体遥控器必须由生产 BLE/HID 证据确认，macOS 系统蓝牙列表中的“已连接”不能单独通过。
- iPhone 与网页版必须由各自生产会话和事件来源确认，不能由同时在线的实体遥控器代替。
- 语音键仍遵守按下即开始、释放即结束的实时路径；不得加入双击等待或长按阈值。
- 实体遥控器连接页的普通按键检查应明确要求短按圆盘中间确定键或方向键，并明确提示不要按麦克风/语音键。
- 在该页收到当前实体遥控器的 ATVV 语音开始事件时，应显示“刚才按的是语音键”的即时纠正状态；这只改善指导和诊断，不得改变 HID 普通按键通过门槛或语音键实时生命周期。
- 诊断应分别记录该页的语音键触发次数、普通控制键观察次数和最后输入类型，不记录设备身份或按键原始报告。

### UI

- 默认内容尺寸为 `1020 × 772`，完整当前页面和底部导航不依赖页面内部滚动。
- 中文最终显示字号不得小于 12pt。
- 浅色和深色必须保持整个窗口视觉体系一致。
- 用户可见文案必须遵守 [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) 的“用户可见文案必须使用产品语言”不变量；平台实现不得把研发、测试或内部验收状态引入页面。
- macOS 页面或流程变化必须按 [`design-qa.md`](../../design-qa.md) 和 [`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md) 完成检查。

## 实现与测试入口

- 产品行为入口：[`PRODUCT_SPEC.md`](PRODUCT_SPEC.md)
- 现有功能说明：[`README.md`](README.md)
- 代码接入点：[`development.md`](development.md)
- 完整测试手册：[`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md)
- 界面规范：[`design-qa.md`](../../design-qa.md)
- 日志规范：[`LOGGING.md`](../../LOGGING.md)
