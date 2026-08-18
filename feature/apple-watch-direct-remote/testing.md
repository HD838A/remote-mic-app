# 测试摘要

## 自动化

- `sayall-mac-remote`：`swift test`，26 项通过，覆盖 Phone/Watch 连接状态回调、语音开始成功、占用、输出未就绪、兼容回调、成功后才发送 `voiceReady`、失败不发送以及停止取消迟到开始结果。
- Mac 主仓：`swift test`，229 项通过，覆盖专用入口顺序、按需监听、取消等待、按键类型映射、`voiceStart → Mac 准备完成 → voiceReady` 首次旅程、同源停止中延迟重启、不同来源互斥和既有稳定功能。
- 2026-08-16 回归：Mac 主仓 222 项、18 个 suite 全部通过；`sayall-mac-remote` 21 项通过，包含 iPhone/Watch 连接状态、语音来源隔离、占用分类、Watch 蓝牙关闭清理、系统 Bonjour 发布确认与发布 watchdog。
- Mac Release：`swift build -c release` 通过；只有既有 `onChange` API 废弃警告。
- GitHub Actions：使用独立只读部署密钥检出固定 revision 的 `sayall-mac-remote`，PR、候选和正式签名流程均通过 SwiftPM 本地 mirror 构建，避免 runner 匿名读取私有仓库且不改写锁定依赖。
- 本次私有组件 PR 的 GitHub Actions 因账号账单/额度问题未启动任何 runner step；失败不来自代码。Apple Silicon 与 Intel Ventura 候选结果仍以发布管理任务中的新候选 CI 为准，本地 26 项组件测试和 229 项主仓测试不能替代两条远端架构线。
- 本机 Release APP 已实际启动：未点击时没有附近监听；点击后日志确认 Phone Bonjour 已发布、Watch BLE 已广播，`dns-sd` 可发现服务；取消等待后两者均停止。

## 人工测试

完整步骤见 [Testing/AppleWatchDirectRemote.md](../../Testing/AppleWatchDirectRemote.md) 和 [Testing/NearbyMobileWaitingCancellation.md](../../Testing/NearbyMobileWaitingCancellation.md)。必须使用真实 Apple Watch、实际测试 Mac、MiRemoteV 2ch 和至少一个真实语音输入工具完成闭环。

## 验证边界

单元测试、本机系统发现和构建只能确认代码、依赖、发布生命周期与静态入口行为。开发代理当前 Mac 不是用户测试 Mac；真实 iPhone/Watch 的本地网络与蓝牙发现、配对弹窗、Mac 蓝牙关闭、麦克风音频、前后台状态和新客户端接管仍需人工验收，未完成前不得表述为真机通过。
