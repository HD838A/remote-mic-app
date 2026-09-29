# 本地测试 App 缺少构建渠道标记

- 时间：2026-09-30
- 状态：已修复，待用户界面验收
- 影响范围：通过 `scripts/build-app.sh` 生成的本地测试 App
- 功能点：本地测试包身份、设置页 Logo 切换测试

## 复现

使用本地测试 App 构建入口传入 `SAYALL_BUILD_CHANNEL=local`：

```zsh
SAYALL_BUILD_CHANNEL=local scripts/build-app.sh
```

App 编译、资源验证和 Developer ID 深度签名均通过，但最终读取构建渠道时失败：

```text
Info.plist: Could not extract value, error: No value at that key path or invalid key path: SayAllBuildChannel
```

## 日志结论

构建入口已经把 `SAYALL_BUILD_CHANNEL=local` 传给原生打包脚本。失败发生在最终
App 的 `Contents/Info.plist` 验证阶段，说明环境变量传递正常，但产物没有对应键。

## 根因

`scripts/build-app.sh` 会复制基础 `Resources/Info.plist` 并写入各项构建能力标记，
但没有读取 `SAYALL_BUILD_CHANNEL`，也没有把 `SayAllBuildChannel` 写入最终 App。
因此调用方传入的本地渠道信息在打包阶段被丢失。

## 修复

打包脚本现在读取可选的 `SAYALL_BUILD_CHANNEL`：

1. 复制基础 plist 后先移除可能残留的 `SayAllBuildChannel`；
2. 环境变量非空时，将其原值写入最终 App；
3. 未提供变量的正式构建保持原有行为，不新增渠道键。

## 验证

- `swift test --disable-keychain --filter buildChannelIsInjectedIntoPackagedInfoPlist`
- 重新执行本地 `all-remotes` Release 构建，确认最终 plist 为
  `SayAllBuildChannel=local`。
- `scripts/verify-app.sh`、`codesign --verify --deep --strict` 和启动烟测。

自动化与启动烟测不能替代设置页中切换 Logo、Dock/Finder 图标刷新以及重新启动后
选择保持的人工验收；这些步骤由本地测试包使用者完成。
