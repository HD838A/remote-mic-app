# Siri Remote 本地打包被嵌套 Helper 最低系统版本校验阻断

## 复现

在 Apple Silicon、macOS 26.6.2 上，使用公开宿主与私有 Siri Remote、Macro package 构建：

```bash
SAYALL_SIRI_REMOTE_PACKAGE_PATH=".../packages/audio-input-kit/siri-remote" \
SAYALL_MACRO_PLATFORM_PATH=".../packages/macos-button-profiles" \
SAYALL_ENABLE_SIRI_REMOTE=1 \
REQUIRE_SAYALL_MACRO_PLATFORM=1 \
SAYALL_OPUS_LIBRARY=".../.build/apple-remote-opus/apple-silicon/install/lib/libopus.0.dylib" \
CODE_SIGN_IDENTITY=- \
./scripts/build-app.sh
REQUIRE_SAYALL_MACRO_PLATFORM=1 ./scripts/verify-app.sh dist/SayAll.app
```

App 构建成功，但 `verify-app.sh` 失败；修复 App 校验后，PKG 的完整 payload 校验也在相同的 HCI Helper 最低系统版本比较处失败。

## 日志结论

构建产物的最低系统版本为：

- `RemoteMic`：14.0
- `SayAllMCP`：14.0
- `SayAllAppleRemoteAudioCapture`：13.0
- `SayAllAppleRemoteHCIService`：13.0
- `libopus.0.dylib`：14.0

失败发生在 App 和 PKG 两层 Siri Remote 嵌套组件的严格字符串比较，并非编译、链接、签名或资源缺失。

## 根因

私有 Siri Remote package 为同时支持 Intel macOS 13 和 Apple Silicon macOS 14，内部 Helper target 声明的 package 平台下限是 macOS 13。嵌套 Helper 在 App 最低系统版本更低是合法的；真正不兼容的情况是 Helper 要求高于 App 发布下限。校验脚本错误地要求所有嵌套组件必须与 App 完全相等。

## 修复

`verify-app.sh` 现在对 Siri Remote 的音频 Helper、HCI Helper 和 Opus 动态库读取 Mach-O 的 `minos`，只拒绝高于当前发布变体最低系统版本的组件，允许较低或相等的版本。`verify-doubao-driver-pkg.sh` 对安装包内展开后的 HCI Helper 使用相同规则。

主 App 和通用 MCP Helper 仍保持原有的精确最低系统版本校验。

## 验证

修复后重新执行：

```bash
REQUIRE_SAYALL_MACRO_PLATFORM=1 ./scripts/verify-app.sh dist/SayAll.app
```

并继续执行 `build-doubao-driver.sh`、`build-doubao-driver-pkg.sh` 与安装包结构校验。

## 边界

本问题只涉及本地/CI 产物验证规则；不代表 Siri Remote 的真实蓝牙、触摸、语音链路或完整安装器 E2E 已通过。
