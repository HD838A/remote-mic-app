# Intel Ventura 独立发行

## 为什么开发

2017 年 Intel Mac 仍可运行 macOS Ventura，但 Apple Silicon 安装包的架构和最低系统版本不兼容。项目需要在不降低 Apple Silicon 发行边界的前提下提供独立 Intel 版本。

## 用户功能介绍

Intel Mac 用户从同一 GitHub Release 下载文件名带 `Intel` 的 DMG，并运行 `Install Remote Mic Intel.pkg`。应用功能、蓝牙遥控、按键映射和语音使用方式与 Apple Silicon 版本一致。

## 范围与非目标

- Intel 使用 `x86_64` 和 macOS 13.0 最低版本。
- Apple Silicon 继续使用 `arm64` 和 macOS 14.0 最低版本。
- 两条发行线使用独立 DMG、PKG、ZIP 和 Sparkle appcast。
- 不生成 Universal 包，不修改蓝牙、HID、ATVV 音频或持久化协议。

## 关键设计与开发过程

- `RELEASE_VARIANT` 统一选择架构、目标三元组、最低系统版本、输出目录、资产名和更新源。
- Intel 安装器在移除旧 App 前检查 `x86_64` 与 macOS 13，避免错误包破坏现有安装。
- Sparkle Framework 在 Intel 包中只保留 `x86_64` slice，`appcast-intel.xml` 防止跨架构更新串包。
- GitHub Actions 日常验证两种架构；受保护的正式打包任务在临时 Keychain 中导入既有 Developer ID 证书，并分别完成签名、公证和 staple。
- 一个 Release 同时携带两套产物，候选溯源记录并校验全部资产；稳定晋升不重新构建。

## 涉及文件

- `Package.swift`
- `Sources/RemoteMic/OnboardingView.swift`
- `Sources/RemoteMic/RemoteMicApp.swift`
- `Sources/RemoteMic/SettingsView.swift`
- `Sources/RemoteMic/UpdateInformationStore.swift`
- `packaging/release-variants/`
- `packaging/doubao-driver/install/`
- `scripts/release-variant.sh`
- `scripts/build-*.sh`、`scripts/verify-*.sh`
- `scripts/notarize-release.sh`
- `scripts/package-macos-release-in-actions.sh`
- `scripts/publish-release.sh`
- `.github/workflows/mac-ci.yml`
- `.github/workflows/mac-preview-candidate.yml`
- `.github/workflows/mac-release-package.yml`

## 隐私与兼容边界

发行变体不会上传新的用户数据。Developer ID 身份只从只读 Match 仓库同步；Notary API Key、Match 密码和 Sparkle 私钥以 age 密文保存在独立私有凭据仓库。受保护的 GitHub Environment 只保存专用解密身份与只读部署密钥，明文只短暂存在于临时 Runner，不进入源码、日志、缓存或发行资产。

## 自动化验证

- 两种 `RELEASE_VARIANT` 的 Swift 测试与 Self Test。
- 注入真实 SayAll AI 私有包后，两种变体的 Swift 测试与 Intel macOS 13 Release 构建。
- `arm64-apple-macosx14.0` 与 `x86_64-apple-macosx13.0` Release 构建。
- App、Sparkle、MiRemoteV、PKG 和 DMG 的架构、最低系统版本、权限、签名、公证和 Gatekeeper 校验。
- 两套 appcast、资产名和候选溯源隔离校验。

## 人工测试手册

见 [Testing/IntelVenturaCompatibility.md](../../Testing/IntelVenturaCompatibility.md)。

## 当前状态和已知限制

当前状态：已完成，多名 Intel Ventura 用户确认安装、蓝牙遥控、按键和语音核心路径可用。

Intel 与 Apple Silicon 必须持续分别打包和回归。Actions 正式打包依赖仓库管理员配置受保护的 `mac-release` Environment、两套私有仓库只读访问和专用 age 身份；未配置时正式打包任务会明确失败，日常无密钥 CI 不受影响。
