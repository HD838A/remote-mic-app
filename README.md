# 无线麦

[English](README.en.md)

[官网](https://sayall.app/) · [配置教程](https://sayall.app/tutorial/)

<p>
  <a href="https://github.com/HD838A/remote-mic-app/stargazers">
    <img src="https://img.shields.io/github/stars/HD838A/remote-mic-app?style=social" alt="GitHub Stars">
  </a>
</p>

<table>
  <tr>
    <td align="center">
      <a href="https://my.feishu.cn/docx/AgEhdekvKoVDUkxkdT0c7BDcnjb"><img src="Screenshots/community-entry-qrcode.png" alt="无线麦 APP 飞书固定入口" width="220"></a><br>
      <strong>飞书固定入口</strong><br>
      <a href="https://my.feishu.cn/docx/AgEhdekvKoVDUkxkdT0c7BDcnjb">点击打开最新加群页面</a>
    </td>
    <td align="center">
      <img src="Screenshots/wechat-group-qrcode.jpg" alt="无线麦 APP 微信群二维码" width="220"><br>
      <strong>微信群二维码</strong><br>
      微信扫码加入交流群
    </td>
    <td align="center">
      <a href="Screenshots/xhs-sayall.jpg"><img src="Screenshots/xhs-sayall.jpg" alt="无线麦小红书二维码" width="220"></a><br>
      <strong>小红书</strong><br>
      扫码关注无线麦
    </td>
  </tr>
</table>

iOS App 公测：[加入 TestFlight 公测](https://testflight.apple.com/join/J8k8fb7v)

Mac App 继续采用官网下载方式分发，Mac App Store 上架暂时暂停；当前 App Store 上架重点只包含 iOS App 与其内嵌的 Apple Watch App。

![无线麦——为 Vibe Coding 而生的语音遥控器](Screenshots/Remote-Mic-Introduce-1.png)

**无线麦，不只听你说。还能替你做，帮你记。**

**开口就输入，一键做更多，说过有回眸。**

无线麦 SayAll 是一款 macOS 应用，可以把兼容的蓝牙语音遥控器变成 Mac 的无线麦。它先让语音输入随手可得，再把常用操作、不同 App 的键位方案和你主动保存的表达连接起来。

无线麦使用 SwiftUI 原生开发，常驻运行时 CPU 占用率低于 0.5%，内存占用约 50 MB，比一个 Chrome 标签页还要轻量。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connection-and-voice-dark-zh.png">
  <img alt="连接与语音设置页" src="Screenshots/connection-and-voice-zh.png">
</picture>

## 无线麦，不只听你说

### 开口就输入

按住说，松开停。开会不发言、听歌不暂停，也能把文字送进正在使用的 App。无线麦不会为了语音输入自动修改 Mac 的默认输入或输出设备。

### 一键做更多（新增能力，真实环境验证中）

组合动作可以把多个受支持的本机步骤依次执行，再绑定到遥控器的单击、双击或长按。它面向稳定、重复的工作流，不等于任意脚本、无限自动化或远程执行。

### 切得准（候选能力，真实环境验证中）

同一只遥控器可以保存多套完整键位方案。你可以手动切换，也可以主动开启按 App 自动匹配；没有匹配规则时回到默认方案。当前仍在进行真实遥控器和第三方 App 的完整验证。

### 说过有回眸（候选能力，等待完整真实语音验收）

主动开启“记录回眸”后，无线麦只保存通过 SayAll 输入并最终稳定出现的文字，按 App 和日期整理在当前 Mac。开启“本地 Agent 访问”后，可以为每个 AI 客户端创建独立、可撤销的只读 MCP 授权。

- 回眸和本地 Agent 访问默认关闭；
- 不保存音频，不读取完整聊天、其他人的回复或输入框前后文；
- 不提供云同步或跨设备同步；
- MCP 通过本机 `stdio` 工作，不监听 HTTP/TCP；
- 无线麦不会主动上传回眸记录，但第三方 AI 客户端可能把读取结果发送给其云端模型。

## 使用要求

- Apple Silicon Mac（macOS 14 或更高版本），或 Intel Mac（macOS 13 或更高版本）；
- 小米蓝牙遥控器 2 Pro；
- 使用语音输入时，需要安装随安装包提供的兼容麦克风，或在 Mac 上已有 BlackHole 2ch 等回环音频设备。

## 下载与安装

- 配置教程：[打开官网配置教程](https://sayall.app/tutorial/)。

- 最新正式版（Apple Silicon）：通过 [Cloudflare CDN 固定入口](https://download.sayall.app/mac) 下载。当前正式版入口仅提供 Apple Silicon 安装包，且不需要随版本更新。
- 最新预览版（Apple Silicon / Intel）：前往 [GitHub Releases](https://github.com/HD838A/remote-mic-app/releases)，在发布列表中寻找最新标记为 **Pre-release** 的 macOS 候选版本，并按 Mac 芯片下载对应 DMG。在包含 Intel 安装包的版本晋升为正式版前，Intel 用户请下载名称带 `Intel` 的最新预览版 DMG。

Apple Silicon 安装包名为 `Remote-Mic-<版本>.dmg`，Intel 安装包名为 `Remote-Mic-<版本>-Intel.dmg`，两者不能混用。

Windows 与 Mac 单独构建和发布。当前仅提供面向小米蓝牙遥控器 2 Pro 的 [Windows 小米蓝牙遥控器 2 Pro Community Preview v0.1.0](https://github.com/HD838A/remote-mic-app/releases/tag/windows-v0.1.0-community-preview)，它是未签名、尚未由主项目维护者独立真机复验的社区预览版，不进入 Mac 的 Sparkle 更新序列。下载前请阅读 Release 中的权限、杀毒软件和虚拟音频设备提示，并使用 `SHA256SUMS.txt` 校验文件。

打开 DMG 后只需双击唯一的 `Install Remote Mic.pkg`；Intel Mac 使用 `Install Remote Mic Intel.pkg`。安装器会把无线麦SayAll.app 安装为 `/Applications/SayAll.app`，并检查现有 `MiRemoteV 2ch`：健康且兼容时原样保留，缺失或不可用时才安装或更新。只需要 App、已经使用其他回环音频设备的高级用户，可从同一 Release 下载 App-only ZIP。

自 v1.3.0 起，正式发布包使用 Apple Developer ID 签名并已完成 Apple 公证。请只从官网 Cloudflare CDN 固定入口或本项目 GitHub Releases 下载；如需核验，请使用同一 GitHub Release 中的 `Remote-Mic-<版本>.dmg.sha256`，它会按文件名列出两种架构的 DMG。

## 首次使用

1. 在“系统设置 → 蓝牙”中打开蓝牙。
2. 同时长按遥控器的“主页”和“菜单”键，使遥控器进入配对状态。
3. 在 Mac 上连接名称为 `MI RC`、`Xiaomi Bluetooth Remote 2`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”的设备。
4. 启动 SayAll.app，按提示允许蓝牙权限。
5. 如果需要自定义普通按键，再允许“输入监控”和“辅助功能”。授权后请完全退出并重新打开应用。

应用启动后会显示 Dock 图标并常驻菜单栏：

- 单击 Dock 图标：打开设置面板；
- 左键单击图标：普通模式打开设置面板；仅状态栏模式直接展开菜单；
- 右键单击图标：显示连接状态、按键快捷映射、重新连接、日志、关于、版本号、检查更新、GitHub 和退出菜单。

应用普通启动时默认打开主面板。设置面板左侧栏底部的“关于”页面提供版本、检查更新、版本历史、术语表、GitHub、语言、Dock 显示和启动行为选项。关闭“启动时自动打开主面板”后，普通启动仅保留菜单栏入口；更新完成并重启时仍会无条件显示主面板。关闭“在 Dock 中显示应用图标”后，应用仍会保留菜单栏入口，可随时重新打开设置。同时关闭这两个选项后进入仅状态栏模式：左键点击图标会直接展开菜单，可在“按键快捷映射”中启停映射、选择已连接遥控器并即时修改各按键的单击动作；双击、长按和需要录入内容的自定义动作继续在完整映射页面编辑。

“应用语言”会完整展示“跟随系统”“简体中文”和“English”三个选项。设置窗口、状态、菜单和内置帮助会随选择刷新；系统权限提示和第三方界面仍会在下次打开时按 macOS 自身的语言显示。

应用每天自动检查一次更新，发现新版本后由用户确认是否安装；不会静默下载或自动安装。“关于”页面和右键菜单中的“检查更新…”均可随时手动检查。“关于”页的“检查预发布版本”默认关闭；开启后，自动检查和手动检查都会包含 GitHub 上最新的 pre-release 候选版本。Sparkle 仅更新应用本体，兼容麦克风驱动仍由 DMG 中的安装包管理。旧版如果仍安装在 `Remote Mic.app` 或 `无线麦.app` 路径，应用内更新会沿用原路径；要迁移到标准 `SayAll.app` 文件名，请运行一次新版 DMG 中的安装 PKG。

## 使用语音输入

1. 打开“连接与语音”页面。
2. 点击“刷新音频设备”。
3. 选择 `MiRemoteV 2ch`，或选择你已经安装的其他回环音频设备。
4. 在需要听写或语音输入的应用中选择同一个设备作为麦克风。
5. 单击目标输入框，按住遥控器语音键说话，松开后结束。

如果想先确认音频链路是否正常，可以点击“发送 1 秒测试音”，或在 QuickTime Player 的“新建音频录制”中观察输入电平。

### Typeless 兼容

Typeless 等点按 Fn 开始、再次点按结束的语音工具，与小米蓝牙遥控器 2 Pro 默认的 Fn 长按行为不兼容。在“连接与语音”中开启“语音键模拟 Fn 点按”后，无线麦会在语音流开始和排空结束时各发送一次 Fn 点按。Typeless 和无线麦仍需选择同一个回环设备，并需授予无线麦“辅助功能”权限。

该模式仍然要求**按住小米蓝牙遥控器 2 Pro 语音键说话、松开结束**；小米蓝牙遥控器 2 Pro 固件在松开语音键后不会继续发送麦克风音频，因此这不是持续录音或免按键模式。开关默认关闭；豆包输入法等使用 Fn 长按的工具应保持关闭。权限或小米蓝牙遥控器 2 Pro HID 映射不完整时，模式会自动关闭并恢复默认 Fn 长按映射。

豆包输入法找不到普通虚拟麦克风时，请使用 DMG 中的 `Install Remote Mic.pkg`，然后在 SayAll.app 中选择 `MiRemoteV 2ch`。详细步骤见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

![豆包输入法 Mac 版选择 MiRemoteV 2ch 麦克风](Screenshots/doubao-input-method-macos.png)

## 自定义遥控器按键

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/key-mapping-dark-zh.png">
  <img alt="按键映射设置页" src="Screenshots/key-mapping-zh.png">
</picture>

打开“按键映射”页面并启用自定义映射后，可以修改方向、确定、返回、主页、菜单、TV、电源和音量键的功能。

每个普通按键都可以设置单击动作，并可额外设置双击和长按动作。动作支持键盘操作、系统音量、播放控制、打开当前 Mac 已安装的常用应用，以及任意自定义键盘快捷键。自定义快捷键既可以直接选择复制、粘贴、聚焦搜索等常用组合，也可以在页面内的标准键盘选择组合键、主键、F1–F20、导航键、数字键盘或单独的左右修饰键；仍保留真实键盘录入入口。

“打开自定义 APP”可以从本机选择任意 `.app`，并选择只打开应用、激活后发送该应用的聚焦快捷键，或记录一次目标输入框后自动聚焦。目标应用升级后如果输入框结构变化，请重新记录；无线麦不会使用固定屏幕坐标，也不会记录输入框中的文字。

- 没有设置双击或长按时，单击保持原有的即时响应和按住重复；
- 设置双击后，应用会等待约 0.3 秒区分单击和双击；
- 设置长按后，按住约 0.55 秒执行长按动作，并抑制单击；
- 设置了双击或长按的实体键不会再按住重复，避免多个动作同时触发。

语音键始终用于语音输入与 Fn 功能，不参与普通按键映射。

## 使用统计

“统计”页面可以按日、周或全部范围查看遥控器按键次数、语音时长，以及从当前版本开始记录的最长单次语音排行。所有统计数据仅保存在本机，不会上传。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/statistics-dark-zh.png">
  <img alt="无线麦使用统计页" src="Screenshots/statistics-zh.png">
</picture>

## AI / Agent 本地配置

无线麦SayAll.app 可以在用户明确授权后，通过随 App 安装的 Swift MCP Helper，让 Codex、Claude Code、Cursor、OpenCode 等客户端只读访问本机“回眸”历史。用户无需安装 Node.js 或其他开发依赖。

需要由 AI 协助完成安装、授权、客户端连接和验证时，请让 AI 阅读：[AI 安装与 MCP 配置指南](AI_SETUP.md)。

## 权限与隐私

- 蓝牙：连接遥控器并接收语音；
- 输入监控：识别遥控器普通按键；
- 辅助功能：把按键动作发送给当前应用。

无线麦不会上传或保存语音，不会自动修改系统默认输入、输出设备，也不会在日志中记录语音内容、蓝牙地址或外设标识。

## 卸载

1. 退出无线麦。
2. 从同一 GitHub Release 下载并运行 `Uninstall Remote Mic.pkg`，移除 `MiRemoteV 2ch` 兼容麦克风。
3. 删除“应用程序”中的 SayAll.app。

卸载兼容麦克风不会修改或删除已有的 BlackHole。

## 遇到问题

请先查看[排障指南](TROUBLESHOOTING.md)。首次安装的完整步骤见[首次安装说明](Resources/首次安装说明.md)。

开发、构建、协议、测试和发布信息见[技术文档](TECHNICAL.md)。

后续开发计划见 [TODO](TODO.md)。

## ⭐ Star History

<p align="center">
  <a href="https://github.com/HD838A/remote-mic-app/stargazers">
    <img src="https://raw.githubusercontent.com/HD838A/remote-mic-app/star-history/assets/star-history.svg" alt="Star History Chart" width="100%">
  </a>
</p>

## ☕️ 请我买 Token

如果「无线麦 SayAll」对你有帮助，欢迎自愿请我买一点 Token。

这些支持会用于支付 AI 开发工具的 Token 费用，帮助我继续为大家开发新功能、优化已有功能、修复问题，让这个项目能够持续迭代。

赞赏完全自愿，不影响软件使用，也不构成任何服务承诺。金额随意，量力而行；无论是否赞赏，都感谢你的使用、反馈和分享。

谢谢你支持「无线麦 SayAll」继续变得更好。

<table>
  <tr>
    <td align="center">
      <img src="Screenshots/donation-wechat.jpg" alt="微信赞赏码" width="280">
      <br>
      微信
    </td>
  </tr>
</table>

## 许可与来源

本仓库中的 macOS App、驱动及相关软件代码采用 `GPL-3.0-only` 许可。iOS App 已由独立私有仓库维护，并继续通过上方 TestFlight 公测入口分发。macOS App 的 Logo 和 App Icon 是需要单独授权的专有品牌资产，详情见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。完整版权和第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)，现由本仓库独立维护。

`MiRemoteV 2ch` 的设备命名及让豆包枚举设备的 USB transport 兼容方案参考自 [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) `v1.0.0-beta.1`（MIT）；该项目的兼容驱动同样基于 BlackHole。本项目不复用 MiRemoteVoice 的二进制替换脚本，而是从 [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) `v0.7.1`（固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`）源码独立派生构建 `MiRemoteV2ch.driver`，适用 `GPL-3.0`。它使用独立标识，可与已安装的 BlackHole 并存，不覆盖或删除其文件。

## 官网

- 中文官网：[sayall.app](https://sayall.app/)
- English website：[sayall.app/en](https://sayall.app/en/)

## 其他作品

- [Vibe PPT Web Template](https://github.com/GetSayAll/vibe-ppt-web-template)
- [Claude Code Config](https://github.com/HD838A/claude-code-config)
- [DJI 4G Mac](https://github.com/HD838A/dji-4g-mac)
