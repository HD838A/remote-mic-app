# Intel Mac / macOS Ventura 兼容性验收

## 范围

Intel 发行线是独立的临时兼容版本，不使用 Universal 包，也不改变 Apple Silicon 正式发行线：

- Intel：`x86_64`、macOS 13.0、`appcast-intel.xml`、文件名带 `Intel`。
- Apple Silicon：`arm64`、macOS 14.0、`appcast.xml`、现有文件名保持不变。

自动化可以验证编译、架构、最低系统版本、安装包内容、Sparkle 结构和 Feed 隔离，但不能替代真实 Intel Mac 上的蓝牙、HID、音频驱动和睡眠唤醒验收。

## 自动化门禁

在 `codex/intel-ventura-support` 分支运行：

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
```

验收结果必须同时满足：

- App、MiRemoteV 2ch 和 Sparkle 的五个可执行文件均只有 `x86_64` 架构。
- App 和驱动的最低系统版本均为 13.0。
- App 的稳定更新地址使用 `appcast-intel.xml`，预览版检查也只寻找该文件。
- Intel 安装包在删除已有 App 前先拒绝错误架构和低于 macOS 13 的系统。
- PKG 安装脚本不调用 `lipo`、`vtool`、`xcrun`、`xcodebuild`、`swift`、`clang` 或其他开发者工具。
- DMG 只包含 Intel App、Intel 安装/卸载 PKG 和 Applications 快捷方式。

## 真实 Intel Ventura 验收清单

使用一台未安装 Xcode 或 Command Line Tools 的 Intel Mac，并从私有测试仓库下载最终签名、公证后的测试包。

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

记录机型、CPU、macOS 小版本、App 版本与构建号、使用的音频设备、发生步骤和准确时间。随后在“控制台”中按 `RemoteMic`、`Autoupdate`、`MiRemoteV2ch` 过滤对应时间段，并一并提供最新的 Remote Mic `.ips` 崩溃报告。

## 完成标准

只有自动化门禁、签名公证、私有仓库下载后复验和上述真实 Intel Ventura 清单全部通过，才可以把 Intel Ventura 标记为正式支持。Rosetta 或 Apple Silicon 上的 `x86_64` 运行只能作为补充验证，不能替代真实 Intel 硬件结果。
