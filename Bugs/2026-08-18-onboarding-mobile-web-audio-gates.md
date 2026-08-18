# Onboarding 手机与网页分支音频门禁错误

## 复现

- iPhone 路径选择已存在的 `MiRemoteV 2ch`，但未从手机开始语音时，音频页持续显示输出未准备好，不能继续。
- 完成一次真实手机语音后，停止语音会释放按需音频输出；进入完成页后“打开无线麦”再次禁用。
- 本地测试包的网页分支显示“网页版暂时不可用”，不能生成二维码。

## 日志与证据

- 现场 `runtime.log` 在 `2026-08-17T18:33:56Z` 的 `mobile_voice_start` 后才出现 `AUDIO READY`，并在 `18:34:01Z` 的 `mobile_voice_stopped` 后执行 `AUDIO RELEASE`。
- 同一会话真实完成 Nearby 连接、手机语音和三个普通按键，排除手机控制链路未连接。
- 本地测试 App 的 `Info.plist` 缺少 `RemoteWebRelayURL`；构建脚本仅在收到私有生产环境变量时写入该配置。

## 根因

iPhone 与网页语音使用按需虚拟音频生命周期，但 Onboarding 音频页和完成页复用了实体遥控器“输出必须持续 Ready”的门禁。网页二维码问题则是本地打包遗漏生产 Relay 配置，并非二维码视图绘制失败。

## 修复

- iPhone/网页在音频页和完成页只要求所选输出设备仍存在；真实输出是否可用继续由下一页会话开始、PCM、停止和文字上屏共同验证。
- 实体遥控器继续要求输出持续 Ready，设备未选择或已消失时所有路径仍阻塞。
- 按产品要求，实体遥控器、iPhone App 和网页版统一要求蓝牙、输入监控和辅助功能全部开启；手机分支的本地网络仍在下一页通过真实连接验证。
- 本地测试包使用发布流程已有的私有生产配置，并设置 `REQUIRE_WEB_REMOTE_CONFIGURATION=1`，缺少 Relay 时直接拒绝打包。

## 验证

- `swift test --filter OnboardingFlowTests`：23 项通过。
- `swift test`：235 项、20 个 suite 通过；`scripts/test.sh` 42 项项目自检与 `swift build` 通过。
- `plutil -lint Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings`：通过。
- iPhone 与网页分支浅色/深色共 40 张生产视图截图已逐张检查，无内部滚动、裁切或黑白分栏。
- 自动化覆盖三条路径统一权限门禁、按需音频差异及设备缺失回归；真实 iPhone Nearby、网页 WSS、Safari 扫码、手机按需语音和第三方输入法文字上屏仍需用户现场验收。
