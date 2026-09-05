# Onboarding macOS 平台适配规范

本文把 [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) 的跨平台产品能力映射到当前 macOS 实现。跨平台产品不变量以产品规范为准；本文只规定 macOS 的具体适配和验收边界。

## 当前平台映射

| 产品能力 | macOS 实现 |
| --- | --- |
| 主控制来源 | 小米蓝牙遥控器 2 / 2 Pro，通过 CoreBluetooth 语音链路和 IOHID 普通按键链路验证 |
| 替代控制来源 | iPhone Nearby 与手机网页版 |
| 必要权限 | 蓝牙、输入监控、辅助功能；具体分支仍以生产能力要求为准 |
| 语音工具 | 豆包输入法、微信输入法、Typeless、其他支持语音输入的工具 |
| Onboarding 语音键 | 豆包、微信和其他工具使用 Fn/地球键长按；Typeless 使用 Fn 点按开始/结束 |
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

- Onboarding 统一使用 Fn/地球键，不在首次流程中提供左/右 Command 选择。
- 旧设置为左/右 Command 时，进入或重跑 Onboarding 应切回 Fn，并显著提示用户发生了什么变化。
- 豆包和微信只能通过公开 Text Input Sources API 按精确 Input Source ID 选择；不得按显示名称模糊匹配。
- Typeless 和其他独立工具不执行系统输入源切换。
- SayAll 不读取豆包、微信或 Typeless 的私有配置；语音识别键、全局唤起和麦克风只能显示期望值并由用户确认。

### 音频

- 当前 Onboarding 只接受产品明确支持的虚拟音频设备，不允许扬声器或普通输出设备通过。
- SayAll 选择的是音频输出端；豆包、微信、Typeless 或其他工具必须把同一设备选择为麦克风输入端。
- 实体遥控器与按需音频来源可以有不同的运行时 Ready 语义，但都必须在真实语音测试中完成音频与文字验证。
- 日志分别记录选择、设备存在、实际绑定、调度、播放、中断、pending 和排空状态。

### 控制来源

- 实体遥控器必须由生产 BLE/HID 证据确认，macOS 系统蓝牙列表中的“已连接”不能单独通过。
- iPhone 与网页版必须由各自生产会话和事件来源确认，不能由同时在线的实体遥控器代替。
- 语音键仍遵守按下即开始、释放即结束的实时路径；不得加入双击等待或长按阈值。

### UI

- 默认内容尺寸为 `1020 × 772`，完整当前页面和底部导航不依赖页面内部滚动。
- 中文最终显示字号不得小于 12pt。
- 浅色和深色必须保持整个窗口视觉体系一致。
- macOS 页面或流程变化必须按 [`design-qa.md`](../../design-qa.md) 和 [`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md) 完成检查。

## 实现与测试入口

- 产品行为入口：[`PRODUCT_SPEC.md`](PRODUCT_SPEC.md)
- 现有功能说明：[`README.md`](README.md)
- 代码接入点：[`development.md`](development.md)
- 完整测试手册：[`Testing/FirstRunOnboarding.md`](../../Testing/FirstRunOnboarding.md)
- 界面规范：[`design-qa.md`](../../design-qa.md)
- 日志规范：[`LOGGING.md`](../../LOGGING.md)
