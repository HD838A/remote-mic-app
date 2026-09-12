# Apple Remote PacketLogger 授权生命周期

## 现象

旧方案让 root helper 直接创建 AuthorizationRef 并连接 `com.apple.bluetooth.BTPacketLogger`。在没有 GUI 会话的 root 进程中，状态会停留在 `authorizing`，最终出现 `packet_stream_authorization_timed_out`。把 external form 跨进程交给 GUI helper 也不能可靠完成授权，且会造成授权凭据归属不清。

## 根因

Authorization Services 的交互认证必须由 GUI 会话中的 SayAll 进程完成。root helper 只应临时准备 HCI tracing 和一个严格绑定 SayAll 签名身份的 `com.apple.PacketLogger.HCI` right；它不应拥有 PacketLogger XPC 会话，也不应把自己的 AuthorizationRef 传给 GUI。

## 修复

- root helper 写入 `class=user`、`group=admin`、`authenticate-user=true`、`shared=false`、`timeout=0`，并绑定 Bundle ID 与 Team ID requirement。
- GUI 使用 `.interactionAllowed + .extendRights + .preAuthorize` 完成管理员认证。
- GUI 获得 AuthorizationRef 后先要求 root helper 恢复原始全局 right，再 externalize 仍在内存中的 AuthorizationRef 给 PacketLogger。
- 授权成功不直接等价于 ready；必须收到 `RequiresAuth=false` 或首个合法 packet，且授权后确认有 15 秒边界，超时进入失败路径。

## 验证边界

自动化已验证编译、授权规则形状的代码路径、XPC 协议和状态机回归。仍需一次真实 GUI 管理员认证以及真实 A2854 语音会话确认 `phase=ready`、PCM 样本和 `MiRemoteV 2ch` 电平。
