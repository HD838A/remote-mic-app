# Apple Remote 授权前早到 packet 被误判

## 复现

在已配对 A2854 的真实机器上启动 1.9.19 (172)。日志先出现连接事件，随后 BTPacketLogger 返回一个只含 `packet` 的合法字典；当前客户端在 `connecting` 阶段把它记录为 `packet_stream_malformed_message_count_1_requires_false_packet_true` 并断开。

## 根因

macOS 某些版本会在 `RequiresAuth` 状态消息之前先投递一条控制器 packet。该 packet 不能证明 AuthorizationRef 已被接受，但也不是 malformed 消息。客户端的状态机只允许 `authorizing`/`streaming` 阶段接收 packet，因此误把正常时序差异当成协议错误。

## 修复与验证边界

在 `connecting` 阶段丢弃这类早到 packet，继续等待 `RequiresAuth=true/false` 或后续授权确认；只有明确就绪后才交付 packet 给 Opus parser。自动化构建与协议回归通过，仍需重新启动真实 App，确认日志能继续进入 `authorization_requested`/`authorizing`，并完成一次真实管理员认证。
