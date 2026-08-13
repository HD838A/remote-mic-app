# 测试摘要

## 自动化

- `sayall-mac-remote`：`swift test`。
- Mac 主仓：`swift test`，覆盖专用入口顺序、按需监听、取消等待、按键类型映射和既有稳定功能。
- Mac Release：按仓库现有发布脚本或 `swift build -c release` 验证。
- GitHub Actions：使用独立只读部署密钥检出固定 revision 的 `sayall-mac-remote`，PR、候选和正式签名流程均通过 SwiftPM 本地 mirror 构建，避免 runner 匿名读取私有仓库且不改写锁定依赖。

## 人工测试

完整步骤见 [Testing/AppleWatchDirectRemote.md](../../Testing/AppleWatchDirectRemote.md) 和 [Testing/NearbyMobileWaitingCancellation.md](../../Testing/NearbyMobileWaitingCancellation.md)。必须使用真实 Apple Watch、实际测试 Mac、MiRemoteV 2ch 和至少一个真实语音输入工具完成闭环。

## 验证边界

单元测试和构建只能确认代码、依赖和静态入口行为。真实 Watch 的本地网络权限、Bonjour 发现、配对弹窗、麦克风音频、前后台状态和新客户端接管仍需人工验收，未完成前不得表述为真机通过。
