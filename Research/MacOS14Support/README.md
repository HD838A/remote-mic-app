# macOS 14 支持评估

## 结论

项目可以把最低系统版本直接降低到 macOS 14.0，并继续只发布 Apple Silicon `arm64` 产物。与最低支持 macOS 15 相比，macOS 14 不需要额外的产品代码分支；主要新增成本是真实 macOS 14 机器上的安装、权限、蓝牙、HID、音频驱动和 Sparkle 更新验证。

不建议把最低版本设为 14.4、14.5 等中间小版本。当前代码在 14.0、14.4 和 15.0 下暴露的编译阻塞完全一致，选择中间版本不会减少改造工作，只会排除更早的 Sonoma 用户。

## 编译探测

使用 Xcode 26.4、macOS 26.4 SDK 和 Swift 6.3，将 SwiftPM 平台临时改为 macOS 14，并分别以以下目标进行 `arm64` 编译：

| 部署目标 | 可用性诊断 | 其他编译错误 |
| --- | ---: | ---: |
| macOS 14.0 | 66 | 0 |
| macOS 14.4 | 66 | 0 |
| macOS 15.0 | 66 | 0 |

三个目标的诊断数量和 API 集合相同，全部位于 `SettingsView.swift`，只涉及 macOS 26 Liquid Glass：

- `GlassEffectContainer`
- `glassEffect(_:in:)`
- `glassEffectID(_:in:)`
- `.glass`
- `.glassProminent`
- `scrollEdgeEffectStyle(_:for:)`

核心蓝牙、HID、ATVV 语音、CoreAudio、配置存储、AppKit 生命周期和 Sparkle 调用没有出现 macOS 14 专属编译错误。

## 依赖和驱动

- Sparkle 2.9.4 的包清单最低支持 macOS 10.13；当前预编译 Framework 的 Apple Silicon slice 最低版本为 macOS 11.0。
- MiRemoteV 2ch 所基于的 BlackHole 0.7.1 工程原始部署目标为 macOS 10.10/12.3。
- 使用当前补丁和构建参数，MiRemoteV 2ch 已成功编译为 `arm64`，Mach-O `minos` 为 14.0。

这些结果证明依赖和驱动没有静态构建层面的 macOS 14 阻塞，但不能替代真实系统上的 HAL 驱动加载、`coreaudiod` 重启和音频路由验证。

## 实现边界

兼容实现应保持现有 macOS 26 外观，不重写页面结构：

- macOS 26 继续使用原生 Liquid Glass 容器、面板、按钮和滚动边缘效果。
- macOS 14/15 使用标准 SwiftUI 控件、系统 Material 背景、描边和选中状态。
- 不修改蓝牙、HID、ATVV、CoreAudio、按键映射、配置格式或 Sparkle Feed 行为。
- App、驱动、PKG、DMG 和 Sparkle ZIP 继续只包含 `arm64`。

最低系统版本必须在以下位置保持一致：

- SwiftPM 平台和 App 编译 triple；
- App `LSMinimumSystemVersion`；
- 音频驱动 `MACOSX_DEPLOYMENT_TARGET`；
- App、驱动、PKG、DMG 验证脚本；
- 安装器的系统版本门禁；
- README、首次安装说明、技术文档和故障排查文档。

## 验收要求

静态和发布机验证：

1. `arm64-apple-macosx14.0` Release 构建和完整测试通过。
2. App 与 MiRemoteV 2ch 的 Mach-O `minos` 均为 14.0。
3. App、Sparkle Framework/XPC/Autoupdate、PKG 和 DMG 的签名、公证、权限及符号链接验证通过。
4. 安装器脚本不依赖 Xcode 或 Command Line Tools。
5. 公开 pre-release 资产与本地产物逐字节一致，候选 appcast 使用固定 Tag URL，稳定 Latest 不改变。
6. App 启动与语言切换不产生 AppKit 菜单项重复挂载异常；重建菜单前必须先把复用的状态项从旧菜单移除。

真实 macOS 14 Apple Silicon 验证：

1. 安装和卸载不要求开发者工具。
2. App 可启动，macOS 14 降级界面完整可用。
3. 蓝牙配对、断线重连、HID 按键、语音键和 ATVV 音频正常。
4. 蓝牙、输入监控和辅助功能权限流程正常。
5. MiRemoteV 2ch 可安装、被系统识别并正常接收音频。
6. 从当前正式版通过候选 Feed 更新成功，更新后 Sparkle helper 权限和 Framework 符号链接保持正确。
7. 睡眠唤醒、音频路由变化和 App 重开不产生新增崩溃。

真实硬件验证是正式晋升的门禁。发布机上的交叉编译、签名和包体检查可以支持 pre-release，但不能单独证明所有 macOS 14 运行时行为。
