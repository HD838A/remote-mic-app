# 无线麦

[English](README.en.md)

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
  </tr>
</table>

iOS App 公测：[加入 TestFlight 公测](https://testflight.apple.com/join/J8k8fb7v)

![无线麦——为 Vibe Coding 而生的语音遥控器](Screenshots/Remote-Mic-Introduce-1.png)

无线麦是一款 macOS 应用，可以把小米蓝牙遥控器 2 Pro 变成 Mac 的无线语音遥控器。它同时提供常规 Dock 入口和常驻菜单栏入口。

按住遥控器的语音键即可说话；遥控器上的方向、确定、返回、主页、菜单、TV 和音量键也可以用来控制 Mac，或设置为打开常用应用。

无线麦使用 SwiftUI 原生开发，常驻运行时 CPU 占用率低于 0.5%，内存占用约 50 MB，比一个 Chrome 标签页还要轻量。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/connection-and-voice-dark-zh.png">
  <img alt="连接与语音设置页" src="Screenshots/connection-and-voice-zh.png">
</picture>

## 使用要求

- Apple Silicon Mac；
- macOS 14 或更高版本；
- 小米蓝牙遥控器 2 Pro；
- 使用语音输入时，需要安装随安装包提供的兼容麦克风，或在 Mac 上已有 BlackHole 2ch 等回环音频设备。

## 下载与安装

发布的安装包会在 [GitHub Releases](https://github.com/HD838A/remote-mic-app/releases/latest) 提供，文件名为 `Remote-Mic-<版本>.dmg`。

Windows 与 Mac 单独构建和发布。当前仅提供面向小米 RC003 的 [Windows RC003 Community Preview v0.1.0](https://github.com/HD838A/remote-mic-app/releases/tag/windows-v0.1.0-community-preview)，它是未签名、尚未由主项目维护者独立真机复验的社区预览版，不进入 Mac 的 Sparkle 更新序列。下载前请阅读 Release 中的权限、杀毒软件和虚拟音频设备提示，并使用 `SHA256SUMS.txt` 校验文件。

打开 DMG 后有两种安装方式：

1. 推荐：双击 Install Remote Mic.pkg。它会同时安装 Remote Mic 和 `MiRemoteV 2ch` 兼容麦克风，适合豆包输入法及其他语音输入应用。
2. 仅安装应用：把 Remote Mic.app 拖到 Applications。如果使用这种方式，请确保 Mac 上已经有可用的回环音频设备。

自 v1.3.0 起，正式发布包使用 Apple Developer ID 签名并已完成 Apple 公证。请只从本项目 GitHub Releases 下载，并使用同一 Release 中的 `.sha256` 文件核对 DMG。

## 首次使用

1. 在“系统设置 → 蓝牙”中打开蓝牙。
2. 同时长按遥控器的“主页”和“菜单”键，使遥控器进入配对状态。
3. 在 Mac 上连接名称为 `MI RC`、`Xiaomi Bluetooth Remote 2`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”的设备。
4. 启动 Remote Mic，按提示允许蓝牙权限。
5. 如果需要自定义普通按键，再允许“输入监控”和“辅助功能”。授权后请完全退出并重新打开应用。

应用启动后会显示 Dock 图标并常驻菜单栏：

- 单击 Dock 图标：打开设置面板；
- 左键单击图标：打开设置面板；
- 右键单击图标：显示连接状态、重新连接、日志、关于、版本号、检查更新、GitHub 和退出菜单。

应用普通启动时默认打开主面板。设置面板左侧栏底部的“关于”页面提供版本、检查更新、版本历史、术语表、GitHub、语言、Dock 显示和启动行为选项。关闭“启动时自动打开主面板”后，普通启动仅保留菜单栏入口；更新完成并重启时仍会无条件显示主面板。关闭“在 Dock 中显示应用图标”后，应用仍会保留菜单栏入口，可随时重新打开设置。

“应用语言”会完整展示“跟随系统”“简体中文”和“English”三个选项。设置窗口、状态、菜单和内置帮助会随选择刷新；系统权限提示和第三方界面仍会在下次打开时按 macOS 自身的语言显示。

应用每天自动检查一次更新，发现新版本后由用户确认是否安装；不会静默下载或自动安装。“关于”页面和右键菜单中的“检查更新…”均可随时手动检查。“关于”页的“检查预发布版本”默认关闭；开启后，自动检查和手动检查都会包含 GitHub 上最新的 pre-release 候选版本。Sparkle 仅更新应用本体，兼容麦克风驱动仍由 DMG 中的安装包管理。

## 使用语音输入

1. 打开“连接与语音”页面。
2. 点击“刷新音频设备”。
3. 选择 `MiRemoteV 2ch`，或选择你已经安装的其他回环音频设备。
4. 在需要听写或语音输入的应用中选择同一个设备作为麦克风。
5. 单击目标输入框，按住遥控器语音键说话，松开后结束。

如果想先确认音频链路是否正常，可以点击“发送 1 秒测试音”，或在 QuickTime Player 的“新建音频录制”中观察输入电平。

### Typeless 兼容

Typeless 等点按 Fn 开始、再次点按结束的语音工具，与 RC003 默认的 Fn 长按行为不兼容。在“连接与语音”中开启“语音键模拟 Fn 点按”后，无线麦会在语音流开始和排空结束时各发送一次 Fn 点按。Typeless 和无线麦仍需选择同一个回环设备，并需授予无线麦“辅助功能”权限。

该模式仍然要求**按住 RC003 语音键说话、松开结束**；RC003 固件在松开语音键后不会继续发送麦克风音频，因此这不是持续录音或免按键模式。开关默认关闭；豆包输入法等使用 Fn 长按的工具应保持关闭。权限或 RC003 HID 映射不完整时，模式会自动关闭并恢复默认 Fn 长按映射。

豆包输入法找不到普通虚拟麦克风时，请使用 DMG 中的 Install Remote Mic.pkg，然后在 Remote Mic 中选择 `MiRemoteV 2ch`。详细步骤见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

![豆包输入法 Mac 版选择 MiRemoteV 2ch 麦克风](Screenshots/doubao-input-method-macos.png)

## 自定义遥控器按键

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Screenshots/key-mapping-dark-zh.png">
  <img alt="按键映射设置页" src="Screenshots/key-mapping-zh.png">
</picture>

打开“按键映射”页面并启用自定义映射后，可以修改方向、确定、返回、主页、菜单、TV、电源和音量键的功能。

每个普通按键都可以设置单击动作，并可额外设置双击和长按动作。动作支持键盘操作、系统音量、播放控制、打开当前 Mac 已安装的常用应用，以及录入任意自定义键盘快捷键。

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

## 权限与隐私

- 蓝牙：连接遥控器并接收语音；
- 输入监控：识别遥控器普通按键；
- 辅助功能：把按键动作发送给当前应用。

无线麦不会上传或保存语音，不会自动修改系统默认输入、输出设备，也不会在日志中记录语音内容、蓝牙地址或外设标识。

## 卸载

1. 退出无线麦。
2. 双击 DMG 中的 Uninstall Remote Mic.pkg，移除 `MiRemoteV 2ch` 兼容麦克风。
3. 删除“应用程序”中的 Remote Mic.app。

卸载兼容麦克风不会修改或删除已有的 BlackHole。

## 遇到问题

请先查看[排障指南](TROUBLESHOOTING.md)。首次安装的完整步骤见[首次安装说明](Resources/首次安装说明.md)。

开发、构建、协议、测试和发布信息见[技术文档](TECHNICAL.md)。

后续开发计划见 [TODO](TODO.md)。

## 许可与来源

本项目的 macOS App、驱动及相关软件代码采用 `GPL-3.0-only` 许可；`Apps/RemoteMicIOS/` iOS 子项目代码同样采用 [GPL-3.0-only](Apps/RemoteMicIOS/LICENSE.md)。两个 App 的 Logo 和 App Icon 都是需要单独授权的专有品牌资产，详情见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。完整版权和第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)，现由本仓库独立维护。

`MiRemoteV 2ch` 的设备命名及让豆包枚举设备的 USB transport 兼容方案参考自 [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) `v1.0.0-beta.1`（MIT）；该项目的兼容驱动同样基于 BlackHole。本项目不复用 MiRemoteVoice 的二进制替换脚本，而是从 [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) `v0.7.1`（固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`）源码独立派生构建 `MiRemoteV2ch.driver`，适用 `GPL-3.0`。它使用独立标识，可与已安装的 BlackHole 并存，不覆盖或删除其文件。

## 官网

- 中文官网：[8586ai.com](https://8586ai.com/)
- English website：[8586ai.com/en](https://8586ai.com/en/)
