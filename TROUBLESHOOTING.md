# 无线麦排障指南

[English](TROUBLESHOOTING.en.md)

请先确认 Mac 为 Apple Silicon，系统版本为 macOS 14 或更高。

## 找不到或连不上遥控器

1. 在“系统设置 → 蓝牙”中确认遥控器已经配对。
2. 同时长按遥控器“主页”和“菜单”键，使其重新进入配对状态。
3. 确认设备名为 `MI RC`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”。
4. 左键单击菜单栏中的无线麦图标打开面板，点击“立即重新连接”。
5. 如果状态一直不变，完全退出无线麦后重新启动，并确认蓝牙权限仍然开启。

应用只连接受支持的小米蓝牙遥控器，不会连接名称相似的其他小米蓝牙设备。

## 按住语音键没有声音

1. 打开“连接与语音”，确认蓝牙状态已连接。
2. 点击“刷新音频设备”，选择 `MiRemoteV 2ch` 或其他可用回环设备。
3. 点击“发送 1 秒测试音”。如果按钮不可用，请重新选择音频设备。
4. 在 QuickTime Player 中选择同一个设备新建音频录制，按住遥控器语音键观察输入电平。
5. 确认目标应用也选择了同一个设备作为麦克风。

应用不会自动修改系统默认输入或输出，因此无线麦和目标应用必须选择同一设备。

## QuickTime 有电平，豆包没有反应

这通常表示遥控器和音频链路已经工作，但豆包没有使用普通虚拟音频设备。

1. 使用 DMG 中的 Install Remote Mic.pkg 安装 `MiRemoteV 2ch`。
2. 完全退出并重新打开豆包。
3. 在无线麦中点击“刷新音频设备”，选择 `MiRemoteV 2ch`。
4. 单击可编辑输入框，确认插入光标已经出现，再按住遥控器语音键。

更多信息见[豆包输入法兼容说明](Resources/豆包输入法兼容说明.md)。

## 普通按键没有反应

1. 打开“按键映射”，启用“自定义按键功能”。
2. 在“权限”页面依次允许输入监控和辅助功能。
3. 完全退出并重新打开无线麦，让系统权限重新生效。
4. 回到按键映射页面，按下实体按键；对应按键应高亮并定位到映射项。

如果未启用自定义映射，macOS 仍可能按普通蓝牙键盘处理部分按键，但不会执行无线麦中设置的动作。

## 按键重复触发或出现系统提示音

应用会选择当前系统允许的按键连接方式，并尽量避免遥控器动作与系统原操作重复触发。

请先：

1. 确认输入监控和辅助功能权限都有效；
2. 恢复默认按键映射后重试；
3. 退出其他正在改写键盘或媒体键的工具；
4. 右键菜单栏图标选择“显示日志”，记录问题发生时的按键和状态。

`1.2.1` 的菜单动作使用 macOS 原生上下文菜单键，不再使用 `Shift-F10`。如果仍有提示音，请在报告中注明实体按键、当前映射、前台应用和按键状态提示。

## 语音键不能触发 Fn

语音键的 Fn 功能只应用于受支持的小米蓝牙遥控器，不会修改 MacBook 键盘或其他设备。

1. 确认蓝牙状态已经显示连接成功；
2. 退出并重新启动无线麦，让设备映射重新应用；
3. 确认遥控器型号为小米蓝牙遥控器 2 Pro；
4. 观察“连接与语音”中的“语音触发”状态。

无线麦退出时会恢复启动前的遥控器语音键设置。

## 安装包被 macOS 阻止

自 v1.3.0 起，正式 Release 的应用、安装/卸载 PKG 和 DMG 均使用 Developer ID 签名并已完成 Apple 公证。若 macOS 仍阻止安装，请删除本地下载件，从本项目 GitHub Releases 重新下载，并核对同一 Release 中的 SHA-256 清单；不要使用来源不明的副本。

同一 Release 的 `Remote-Mic-<版本>.dmg.sha256` 同时列出 Apple Silicon 与 Intel DMG。只下载其中一个 DMG 时，可按精确文件名核对：

```bash
grep -F "  Remote-Mic-<版本>.dmg" \
  "Remote-Mic-<版本>.dmg.sha256" | shasum -a 256 -c -
```

## 自动更新提示 Autoupdate 没有执行权限

如果 Console 中出现以下任一信息，问题不在 appcast、下载网络或更新包签名，而是当前已安装应用中的 Sparkle 更新器失去了执行权限：

```text
The remote port connection was invalidated from the updater.
Autoupdate may not have executable permissions.
failed to probe status service for com.hd838a.RemoteMic
```

旧版 `1.4.2` / `1.4.3` 的安装 PKG 曾把应用内所有普通文件统一改为 `0644`，但只恢复了主程序的执行权限，因而 `Autoupdate`、Updater 和两个 XPC 服务无法启动。重新检查更新或重新安装同一旧版 PKG 不会修复；损坏的更新器也不能通过自动更新修复自身。

首选恢复方式是下载对应架构的最新 DMG，挂载后运行其中唯一的安装 PKG。Release 不再重复上传 standalone Installer PKG；远程管理脚本也应从 DMG 读取同一份已签名、公证安装器。如果只能使用远程终端，也可直接执行下面的权限恢复：

```bash
sudo chmod 755 \
  "/Applications/Remote Mic.app/Contents/MacOS/RemoteMic" \
  "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
  "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
  "/Applications/Remote Mic.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"

codesign --verify --deep --strict "/Applications/Remote Mic.app"
```

远程修复不要求物理接触 Mac；但 Sparkle 的安装确认界面需要处于已解锁的图形会话。锁屏状态下成功取得 appcast（HTTP 200）只证明更新源可访问，不能视为已完成升级。

## 查看日志

右键单击菜单栏图标，选择“显示日志”。日志文件位于：

```text
~/Library/Logs/RemoteMic/runtime.log
```

日志不会记录语音内容、蓝牙地址或设备唯一标识。提交问题时请附上系统版本、Mac 芯片、遥控器型号、复现步骤和相关日志片段。
