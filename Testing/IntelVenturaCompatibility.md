# Intel Mac / macOS Ventura 兼容性验收

## 范围

Intel 发行线是独立的正式兼容版本，不使用 Universal 包，也不改变 Apple Silicon 发行线：

- Intel：`x86_64`、macOS 13.0、`appcast-intel.xml`、文件名带 `Intel`。
- Apple Silicon：`arm64`、macOS 14.0、`appcast.xml`、现有文件名保持不变。

自动化可以验证编译、架构、最低系统版本、安装包内容、Sparkle 结构和 Feed 隔离，但不能替代真实 Intel Mac 上的蓝牙、HID、音频驱动和睡眠唤醒验收。

Apple Silicon 与 Intel 继续分别发布，不生成 Universal 包。两个安装 PKG 都使用系统 Installer 的产品归档：用户打开错误架构的 PKG 时，安装器应在复制 payload 和请求管理员授权前显示本地化错误，并明确说明应下载另一架构版本。

## 自动化门禁

在 `main` 运行：

```zsh
RELEASE_VARIANT=intel swift test
RELEASE_VARIANT=intel ./scripts/test.sh
RELEASE_VARIANT=intel swift build -c release --triple x86_64-apple-macosx13.0
RELEASE_VARIANT=intel ./scripts/build-app.sh
RELEASE_VARIANT=intel ./scripts/verify-app.sh
RELEASE_VARIANT=intel ./scripts/build-doubao-driver.sh
RELEASE_VARIANT=intel ./scripts/build-doubao-driver-pkg.sh
RELEASE_VARIANT=intel BUILD_COMPONENTS=0 ./scripts/build-dmg.sh
RELEASE_VARIANT=intel ./scripts/verify-dmg.sh
./scripts/test-installer-architecture-guard.sh
```

验收结果必须同时满足：

- App、MiRemoteV 2ch 和 Sparkle 的五个可执行文件均只有 `x86_64` 架构。
- App 和驱动的最低系统版本均为 13.0。
- App 的稳定更新地址使用 `appcast-intel.xml`，预览版检查也只寻找该文件。
- 外层 Distribution 使用 `system.sysctl('hw.optional.arm64')` 判断真实硬件，不依赖可能受 Rosetta 影响的 `uname -m`；错误架构和过低系统必须以 `Fatal` 本地化消息拒绝。
- 内层 preinstall 与 postinstall 保留相同的硬件和系统防御检查，且在删除或替换已有 App、驱动前执行。
- PKG 安装脚本不调用 `lipo`、`vtool`、`xcrun`、`xcodebuild`、`swift`、`clang` 或其他开发者工具。
- DMG 根目录只包含对应架构的安装 PKG；卸载 PKG 和 App-only ZIP 继续作为 Release 高级资产。

## 错误架构安装包验收

必须使用最终 Developer ID 签名、公证并 staple 的候选产物完成以下交叉检查，不能用 ad-hoc 包替代：

1. 在 Apple Silicon Mac 上打开 `Install Remote Mic Intel.pkg`。预期 Installer 在进入安装步骤前显示“此安装包仅适用于 Intel Mac”，并提示下载文件名不带 `Intel` 的 Apple Silicon 版本。
2. 关闭错误提示，确认没有请求管理员密码，没有改动 `/Applications/SayAll.app` 或旧版 `/Applications/Remote Mic.app`、`/Applications/无线麦.app`，也没有新增或替换 `/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver`。
3. 在同一台 Mac 打开 `Install Remote Mic.pkg`。预期能够进入正常安装流程。
4. 在真实 Intel Ventura Mac 上打开 `Install Remote Mic.pkg`。预期 Installer 在进入安装步骤前显示“此安装包仅适用于 Apple 芯片 Mac”，并提示下载文件名带 `Intel` 的版本。
5. 关闭错误提示并确认 App、驱动均未变化；随后打开 `Install Remote Mic Intel.pkg`，确认能够进入正常安装流程。
6. 分别在中文和英文系统语言下重复错误包检查，确认错误内容跟随 Installer 界面语言，而不是安装脚本的 `LANG` 环境变量。

任一错误包能够继续进入授权或复制文件、提示只显示内部架构值 `arm64` / `x86_64`、没有指出另一安装包、语言错误，或关闭后 App/驱动发生变化，都判定为失败。使用命令行只读执行 `installer -showChoicesXML -pkg <PKG> -target /` 可以验证 Distribution 拒绝原因，但不能替代 Installer.app 的真实界面验收。

## 真实 Intel Ventura 验收清单

使用一台未安装 Xcode 或 Command Line Tools 的 Intel Mac，并从 GitHub Release 下载最终签名、公证后的 Intel 测试包。

1. 下载后核对 SHA-256，打开 DMG，确认 Gatekeeper 不提示来源或完整性异常。
2. 运行 `Install Remote Mic Intel.pkg`，确认普通管理员授权即可完成安装，不要求下载开发者工具。
3. 首次启动完成蓝牙、输入监控和辅助功能权限流程；已安装过旧版本的用户不应重新进入完整 Onboarding。
4. 配对小米蓝牙遥控器 2 Pro，验证连接、断开、重连和实体按键事件。
5. 验证单击、双击、长按映射，尤其确认 Fn 语音输入第一次触发即可向当前聚焦输入框输入。
6. 验证 ATVV 语音开始、PCM 到达、松开结束，以及连续多次语音输入。
7. 分别选择 MiRemoteV 2ch 和 BlackHole 2ch，确认两种音频回环设备都可完成语音输入。
8. 验证 iOS 附近连接与网页版连接入口，不改变现有邀请码和服务配置行为。
9. 让 Mac 睡眠后唤醒，验证 App 不崩溃，遥控器、HID、音频设备和菜单栏状态能够恢复。
10. 使用 Intel 测试 Feed 验证同架构跨版本更新；不得下载或安装 Apple Silicon 资产。
11. 运行 `Uninstall Remote Mic Intel.pkg`，确认驱动移除、Core Audio 刷新且 App 的既有卸载行为不变。

## 失败时收集信息

记录机型、CPU、macOS 小版本、系统语言、App 版本与构建号、安装包完整文件名、使用的音频设备、发生步骤和准确时间。安装器门禁失败时同时保存 Installer 错误截图和 `/var/log/install.log` 对应时间段；运行功能失败时再在“控制台”中按 `RemoteMic`、`Autoupdate`、`MiRemoteV2ch` 过滤，并一并提供最新的 Remote Mic `.ips` 崩溃报告。

## GitHub Actions 打包边界

日常 `macOS CI` 与预览候选 workflow 会分别构建 Apple Silicon 和 Intel 产物。正式签名、公证打包使用 `macOS Signed Release Packages` workflow，并限制在受保护的 `mac-release` Environment。该 Environment 需要配置：

- `SAYALL_AI_DEPLOY_KEY`
- `RELEASE_CREDENTIALS_DEPLOY_KEY`
- `APPLE_SIGNING_MATCH_DEPLOY_KEY`
- `RELEASE_AGE_IDENTITY`
- `REMOTE_WEB_RELAY_URL`
- `EARLY_ACCESS_SERVICE_URL`

`SAYALL_AI_DEPLOY_KEY` 可以继续作为仓库 Secret；其余发布值应放在受保护的 `mac-release` Environment。Developer ID 身份只从只读 Match 仓库同步，P8、Match 密码和 Sparkle 私钥只以 age 密文存在于独立私有凭据仓库；Environment 仅保存专用 age 身份和两把只读部署密钥。解密文件只存在于临时 Runner 与临时 Keychain，不写入源码、缓存或 Actions Artifact。workflow 输出两套独立的已签名、公证、stapled 产物；发布与稳定晋升仍由候选溯源门禁处理。

正式 workflow 必须注入真实 SayAll AI 私有包并在两种发行变体下运行测试。私有包的最低平台必须保持为 macOS 13 或更低；只验证未注入私有包的公开构建不能证明 Intel 生产包可用。

## 当前状态

Intel Ventura 已经过多名用户测试，安装、启动、蓝牙遥控、按键和语音核心路径可以正常使用，现作为正式支持发行线。错误架构提示的 Distribution 结构、双变体 ad-hoc PKG/DMG 和 Apple Silicon 上的 Intel 包拒绝路径已完成自动化或只读验证；最终 Developer ID 包的 Installer.app 双语言界面，以及真实 Intel Mac 打开 Apple Silicon 包，仍需按上方交叉清单验收。自动化、签名、公证和多人实测各自证明其覆盖边界；Rosetta 或 Apple Silicon 上的 `x86_64` 运行仍不能替代真实 Intel 硬件回归。
