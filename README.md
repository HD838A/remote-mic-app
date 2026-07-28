# 无线麦

![无线麦——为 Vibe Coding 而生的语音遥控器](Screenshots/Remote-Mic-Introduce-1.png)

无线麦是一款 macOS 菜单栏应用，可以把小米蓝牙遥控器 2 Pro（RC003）变成 Mac 的无线语音遥控器。

按住遥控器的语音键即可说话；遥控器上的方向、确定、返回、主页、菜单、TV 和音量键也可以用来控制 Mac，或设置为打开常用应用。

![连接与语音设置页](Screenshots/connection-and-voice.png)

## 使用要求

- Apple Silicon Mac；
- macOS 26 或更高版本；
- 小米蓝牙遥控器 2 Pro / RC003；
- 使用语音输入时，需要安装随安装包提供的兼容麦克风，或在 Mac 上已有 BlackHole 2ch 等回环音频设备。

## 下载与安装

发布的安装包会在 [GitHub Releases](https://github.com/HD838A/remote-mic-app/releases/latest) 提供，文件名为 `Remote-Mic-<版本>.dmg`。

打开 DMG 后有两种安装方式：

1. 推荐：双击“安装无线麦.pkg”。它会同时安装“无线麦”和 `MiRemoteV 2ch` 兼容麦克风，适合豆包输入法及其他语音输入应用。
2. 仅安装应用：把“无线麦.app”拖到 Applications。如果使用这种方式，请确保 Mac 上已经有可用的回环音频设备。

当前安装包尚未进行 Apple 公证。若 macOS 阻止打开，请前往“系统设置 → 隐私与安全性”，确认文件来自你信任的来源后选择继续打开。

## 首次使用

1. 在“系统设置 → 蓝牙”中打开蓝牙。
2. 同时长按遥控器的“主页”和“菜单”键，使遥控器进入配对状态。
3. 在 Mac 上连接名称为 `MI RC`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”的设备。
4. 启动“无线麦”，按提示允许蓝牙权限。
5. 如果需要自定义普通按键，再允许“输入监控”和“辅助功能”。授权后请完全退出并重新打开应用。

应用启动后常驻菜单栏：

- 左键单击图标：打开设置面板；
- 右键单击图标：显示连接状态、重新连接、日志、关于、版本号、检查更新、GitHub 和退出菜单。

应用不会自动检查更新；只有从右键菜单选择“检查更新…”时才会访问更新源。Sparkle 仅更新应用本体，兼容麦克风驱动仍由 DMG 中的安装包管理。

## 使用语音输入

1. 打开“连接与语音”页面。
2. 点击“刷新音频设备”。
3. 选择 `MiRemoteV 2ch`，或选择你已经安装的其他回环音频设备。
4. 在需要听写或语音输入的应用中选择同一个设备作为麦克风。
5. 单击目标输入框，按住遥控器语音键说话，松开后结束。

如果想先确认音频链路是否正常，可以点击“发送 1 秒测试音”，或在 QuickTime Player 的“新建音频录制”中观察输入电平。

豆包输入法找不到普通虚拟麦克风时，请使用 DMG 中的“安装无线麦.pkg”，然后在无线麦中选择 `MiRemoteV 2ch`。详细步骤见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

## 自定义遥控器按键

![按键映射设置页](Screenshots/key-mapping.png)

打开“按键映射”页面并启用自定义映射后，可以修改方向、确定、返回、主页、菜单、TV、电源和音量键的功能。

每个普通按键都可以设置单击动作，并可额外设置双击和长按动作。动作支持键盘操作、系统音量、播放控制、打开当前 Mac 已安装的常用应用，以及录入任意自定义键盘快捷键。

- 没有设置双击或长按时，单击保持原有的即时响应和按住重复；
- 设置双击后，应用会等待约 0.3 秒区分单击和双击；
- 设置长按后，按住约 0.55 秒执行长按动作，并抑制单击；
- 设置了双击或长按的实体键不会再按住重复，避免多个动作同时触发。

语音键始终用于语音输入，不参与普通按键映射。

## 权限与隐私

- 蓝牙：连接遥控器并接收语音；
- 输入监控：识别遥控器普通按键；
- 辅助功能：把按键动作发送给当前应用。

无线麦不会上传或保存语音，不会自动修改系统默认输入、输出设备，也不会在日志中记录语音内容、蓝牙地址或外设标识。

## 卸载

1. 退出无线麦。
2. 双击 DMG 中的“卸载无线麦.pkg”，移除 `MiRemoteV 2ch` 兼容麦克风。
3. 删除“应用程序”中的“无线麦.app”。

卸载兼容麦克风不会修改或删除已有的 BlackHole。

## 遇到问题

请先查看[排障指南](TROUBLESHOOTING.md)。首次安装的完整步骤见[首次安装说明](Resources/首次安装说明.md)。

开发、构建、协议、测试和发布信息见[技术文档](TECHNICAL.md)。

## 许可与来源

本项目软件代码采用 `GPL-3.0-only` 许可。App Logo 是需要单独授权的专有品牌资产，详情见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。完整版权和第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

项目最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)，现由本仓库独立维护。

`MiRemoteV 2ch` 的设备命名及让豆包枚举设备的 USB transport 兼容方案参考自 [VincentKingHsu/MiRemoteVoice](https://github.com/VincentKingHsu/MiRemoteVoice) `v1.0.0-beta.1`（MIT）；该项目的兼容驱动同样基于 BlackHole。本项目不复用 MiRemoteVoice 的二进制替换脚本，而是从 [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) `v0.7.1`（固定提交 `e2b22aaaba4e507a097131704bf96dabc004d9cf`）源码独立派生构建 `MiRemoteV2ch.driver`，适用 `GPL-3.0`。它使用独立标识，可与已安装的 BlackHole 并存，不覆盖或删除其文件。
