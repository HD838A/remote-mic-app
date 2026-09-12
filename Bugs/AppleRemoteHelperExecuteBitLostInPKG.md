# PKG 安装后 Apple Remote 音频 helper 不可执行

## 复现

- 环境：macOS 26.5.2、Apple Silicon、Developer ID 签名的 `1.9.19 (172)` 本地候选 PKG。
- 前置条件：未安装 PacketLogger.app，未安装 Bluetooth Logging Profile，安装前不存在 SayAll HCI LaunchDaemon 和 HCI debug plist。
- 操作：使用系统 Installer 安装包含 SayAll.app、MiRemoteV 2ch 和 Apple Remote HCI 服务的合并 PKG，等待安装器自动启动 App。
- 错误行为：App 启动后日志记录 `APPLE REMOTE AUDIO component=unavailable reason=helper_missing`；HCI LaunchDaemon 已注册但从未运行。
- 正常边界：安装包内确实存在 Apple Remote 音频 helper，构建前它具有执行权限且签名有效。

## 日志与现场证据

- 安装后 `/Applications/SayAll.app/Contents/Helpers/SayAllAppleRemoteAudioCapture` 存在、SHA-256 与候选包一致，但权限为 `0644`。
- 同目录的 `SayAllMCP` 和包内 HCI helper 同样为 `0644`。
- HCI debug plist 与服务状态文件均不存在，证明失败发生在 App 启动 helper 之前，没有留下系统配置。

## 根因

`packaging/doubao-driver/install/postinstall` 会在安装后恢复 App 可执行文件权限，但 `APP_EXECUTABLES` 只列出主程序和 Sparkle 组件，遗漏三个 `Contents/Helpers` 可执行文件。PKG payload 安装时将这些文件归一化为普通文件权限，导致 `FileManager.isExecutableFile` 返回 false。

## 修复

把 `SayAllMCP`、`SayAllAppleRemoteAudioCapture` 和包内 `SayAllAppleRemoteHCIService` 的固定路径加入 `APP_EXECUTABLES`，沿用现有逐项 `chmod 755`、可执行性检查和最终 `codesign --deep --strict` 验证。PKG 静态验证器同步要求这三个路径必须出现在安装后权限恢复列表中。

## 验证边界

- 必须重新构建并安装 Developer ID 候选 PKG，确认三个 helper 均为 `0755`。
- 必须确认 App 日志不再出现 `helper_missing`，HCI LaunchDaemon 被按需唤醒并完成预热。
- 真实遥控器音频、Opus、MiRemoteV 2ch 和豆包最终转写仍需在 helper 启动后独立验证，不能由本修复的文件权限结果代替。
