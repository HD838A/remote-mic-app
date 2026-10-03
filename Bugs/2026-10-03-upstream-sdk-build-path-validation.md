# 第三方 SDK 构建路径校验

## 证据

本地主线集成 App 编译、签名完成后，verify-app.sh 的通用 /Users 路径检查失败。主可执行文件的116个不同路径均来自固定版本 Sentry SDK 的公开 CI 源目录 /Users/runner/work/sentry-cocoa/sentry-cocoa/Sources/；未包含本机用户名或工作区路径。

## 修复与边界

仅对上述精确上游源路径豁免，其余 /Users 路径、临时 remote-bridge 路径和示例设备地址继续拒绝。未修改 SDK 或 App 字节，不关闭整个路径校验。

## 验证

PCRE 匹配实验确认精确上游路径通过，本机路径、不同 runner 目录、相似前缀、临时路径和示例设备地址仍拒绝。最终完整 App 校验结果见本轮交付记录。
