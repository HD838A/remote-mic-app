# 功能档案

每个正式功能使用独立的 kebab-case 子目录，记录公开行为、实现范围、验证方式、人工测试步骤和已知限制。详细研究与长期计划仍保存在私有 marketing 仓库。

## 功能索引

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| [关于页版本中心](./about-update-center/) | 验证中 | 集中展示版本、更新内容、版本历史与正式/预发布更新通道。 |
| [Apple Watch 直连遥控与收音](./apple-watch-direct-remote/) | 候选代码完成，等待真机验收 | Mac 提供独立 Watch 入口，并复用按需开启的附近连接、现有按键映射与移动语音链路。 |
| [常用 macOS 快捷键](./common-mac-shortcuts/) | 已完成 | 常用固定快捷键与无线麦标准退出、关窗行为。 |
| [Mac 下载 Cloudflare CDN](./cloudflare-download-cdn/) | 等待预览版集成 | 官网固定入口与 Worker 已上线；版本化安装包和 Sparkle 更新资产通过 Cloudflare 缓存 GitHub Release 源文件，候选验证由统一 Mac 预览版完成。 |
| [私有功能组件集成](./private-feature-integration/) | 已完成 | 公开 App 只保留可选适配层；私有实现、资源、测试和内部文档由独立私有组件维护。 |
| [快捷指令私有模块集成](./quick-commands-private-integration/) | 代码完成，等待人工验收 | 通过可选私有 Swift Package、Feature Flag 和邀请码提供快捷指令页面与遥控器绑定，公开构建保持独立。 |
| [Intel Ventura 独立发行](./intel-ventura-release/) | 已完成 | Intel 使用 macOS 13、x86_64、独立安装包与更新源，并与 Apple Silicon 分别打包。 |
| [本地语音转写记录](./local-transcript-history/) | 修复完成，等待人工验收 | 默认关闭；独立侧边栏页面按目标 App 和日期展示带 App 图标的本地转写记录，不依赖 AI 或 API Key。 |
| [首次使用成功率优化](./first-use-success/) | 候选代码完成，等待安装验收 | 设置卡点提供单一修复动作与脱敏诊断；普通 DMG 只保留一个安装入口并保留健康驱动。 |
| [延长语音录音与 iOS 点按录音](./extended-voice-recording/) | 部分撤回，等待人工验收 | 普通遥控器 `MIC_EXTEND` 延长方案已撤回；iOS 支持点按切换与按住说话。 |
| [系统占用快捷键录入](./reserved-shortcut-capture/) | 等待人工验收 | 点击录入后短暂捕获被系统或其他 APP 占用的组合键，并显示明确成功或失败反馈。 |
| [首次使用设置向导](./first-run-onboarding/) | 等待人工验收 | 仅全新安装通过不可跳过的实时门禁完成语音工具、优先实体遥控器或无遥控器时的 iPhone/网页版、对应权限、兼容麦克风、真实语音文字和普通按键检查；旧安装升级自动迁移。 |
| [首选输入法自动准备](./preferred-input-source-switching/) | 候选代码完成，等待真实输入法验收 | 记住 Onboarding 中选择的豆包或微信输入法，在 Fn 按下时使用精确输入源 ID 按需切换。 |
| [唤起目标后的首次语音就绪协调](./voice-input-destination-readiness/) | 等待人工验收 | 目标输入位置真正就绪后再启动第一次 Fn 语音，并在等待期间完整缓存短语音。 |
| [问题反馈入口](./issue-feedback-link/) | 等待人工验收 | 从状态栏直接打开 SayAll 工作台最低权限页面，不接入账号或设备认证。 |

## 新功能模板

创建新目录时至少回答：

1. 用户遇到了什么问题，为什么现在开发？
2. 用户可以看到和操作什么？
3. 本次明确做什么、不做什么？
4. 数据会读到哪里、发送到哪里、保存在哪里？
5. 修改了哪些文件和共享链路，为什么？
6. 开发中遇到了什么关键问题，最终如何处理？
7. 自动化、构建、真机和第三方 App 分别验证到什么边界？
8. 用户应按照什么步骤测试，什么结果属于失败？
