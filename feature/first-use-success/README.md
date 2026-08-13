# 首次使用成功率优化

## 为什么开发

首次设置任一权限、遥控器、音频或语音环节失败时，用户过去只能看到“不能继续”，难以判断下一步。安装 DMG 同时展示多个入口，也会让普通用户不知道应该双击 PKG 还是拖动 App。

## 用户功能

- 每个未通过的设置阶段显示一个明确原因和一个主要修复操作。
- 完成页发现权限、遥控器或音频状态变化时，直接返回对应阶段。
- 可复制脱敏设置诊断，包含版本、系统大版本、架构、布尔状态、失败码、阶段耗时和重试结果。
- 普通 DMG 只展示一个安装 PKG；安装器同时安装 App，并仅在兼容麦克风缺失、损坏、架构不符、签名异常或版本不匹配时替换它。

## 范围与非目标

- 不改名或迁移 `MiRemoteV 2ch`，不修改其 UID、Bundle ID 或音频行为。
- 不修改蓝牙协议、PCM、按键报告、默认映射或用户配置格式。
- 不上传诊断或使用数据，不保存音频、用户文字、设备名称、设备标识、路径或密钥。
- App-only ZIP 和卸载 PKG 继续作为高级发行资产保留，但不与普通安装入口并列。

## 相关文件

- `Sources/RemoteMic/FirstUseDiagnostics.swift`
- `Sources/RemoteMic/AppSettings.swift`
- `Sources/RemoteMic/OnboardingFlow.swift`
- `Sources/RemoteMic/OnboardingView.swift`
- `packaging/doubao-driver/install/postinstall`
- `scripts/build-dmg.sh`
- `scripts/build-doubao-driver-pkg.sh`
- `Testing/FirstUseSuccess.md`

## 当前状态与验证边界

失败码、事件去重、脱敏摘要、定向回跳、单入口结构和健康驱动保留策略已有自动化或静态检查。本轮按要求不生成 PKG/DMG，因此全新安装、已有驱动保留、损坏驱动替换、管理员取消和安装后启动仍需在后续预览包上执行真实安装验收。
