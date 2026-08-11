# 邀请制 AI 整理

- 状态：候选验证中
- 平台：macOS
- 功能标识：`deepseek_post_dictation`
- 详细设计：私有产品资料库 `projects/remote-mic-app/research/invite-only-feature-access/v1/wireless-mic-integration-design.md`

## 为什么开发

AI 整理仍处于受控体验阶段，但测试人员需要使用与普通用户相同的正式签名 App 和更新通道。仅靠隐藏菜单或本地布尔值无法限制人数、撤销资格或远程暂停，因此在客户端接入通用 Early Access 协议。

## 用户功能

- 普通用户看不到“AI 整理”侧边栏、页面或邀请码入口。
- 首次兑换入口仅在内部启动参数明确开启时显示；用户输入体验码并手动点击前，不创建匿名设备 ID，也不请求资格服务。已有本机资格的用户仍可查看状态和退出体验。
- 授权后显示“AI 整理”，但本地开关保持关闭，必须由用户主动开启。
- 已加入用户只在启动、唤醒、资格要求刷新或主动重新检查时低频续期；每次语音不会访问资格服务。
- 退出、撤销、暂停、过期、签名异常或版本阻止会关闭并取消 AI 整理，迟到结果不得写回。

## 范围与非目标

本功能只消费通用 Early Access Platform 的公开协议，不在平台仓库加入无线麦页面、产品文案、DeepSeek 逻辑或音频代码。本次不新增账号系统，不代理 DeepSeek 请求，不把资格网络请求放进蓝牙、音频、HID、iPhone 或 Web Remote 链路。

## 数据与隐私

资格服务只接收体验码、随机匿名设备 ID、App 版本、Build、平台和功能标识。匿名 ID、Grant、刷新凭证和签名授权保存在独立 Keychain 项中，不进入 UserDefaults、配置导出或日志。

DeepSeek API Key 继续保存在独立 Keychain 项，术语继续保存在本机文件。资格失效不会删除这两类数据。资格服务不会接收语音、转写文字、DeepSeek API Key 或整理结果。

## 关键实现

- `EarlyAccessEntitlement.swift`：内置受信任 Ed25519 公钥，严格验证 JWS 结构、签名、App、功能、Grant、Subject、时间和版本范围。
- `EarlyAccessCredentialStore.swift`：首次人工兑换时生成匿名 ID，原子保存轮换后的 Grant Bundle。
- `EarlyAccessClient.swift`：只实现通用 redeem、refresh 和 release API，生产服务地址由私有发布配置注入。
- `EarlyAccessController.swift`：统一发布资格状态和同步有效资格布尔值，处理离线有效、明确拒绝、暂停、撤销和退出。
- `BridgeAppModel.swift`：把资格与本地开关、DeepSeek Key 组合为唯一运行条件，并在资格失效时统一取消。
- `SettingsView.swift`：过滤导航、提供关于页内联体验面板和授权后的 AI 页面。

## 验证边界

自动化覆盖首次不联网、普通启动不显示邀请入口、签名与 Claims、Keychain、离线缓存、明确撤销，以及“资格缺失 / 有资格但关闭 / 有资格且开启 / 使用后撤销”四态。完整人工步骤见 [`Testing/EarlyAccessAIPolish.md`](../../Testing/EarlyAccessAIPolish.md)。构建、签名、公证和自动化不能替代真实 RC003、豆包输入法、DeepSeek 和不同 AX 输入框验收。该实验不得出现在应用内版本历史、Sparkle 更新说明或 GitHub Release Notes 中。

当前候选验证结果：

- Early Access、DeepSeek、后整理和术语定向测试：24 项、10 个 Suite 通过；
- 完整 SwiftPM 回归：232 项、30 个 Suite 通过；
- 私有硬件模拟回归：16 项、1 个 Suite 通过，包含 RC003 无前置 `MIC_OPEN` 的 `STREAM_START → AUDIO → STREAM_STOP` 和停止后尾音保留；
- Release 构建和 App Bundle 校验通过；功能分支保持原版本号，不执行签名公证或发布；
- 当前 Mac 锁屏，Computer Use 无法完成 `1020 × 772`、`800 × 650` 逐页界面验收；真实 RC003、豆包、DeepSeek、附近 iPhone、Web Remote 和第三方 AX 输入框仍待主协调会话或真实环境验收。
