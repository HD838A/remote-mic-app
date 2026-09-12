# Siri Remote 语音在本地测试 App 中失效

## 状态

- 状态：根因已确认，修复待验证
- 时间：2026-09-12
- 影响：包含私有 Siri Remote 组件的本地 ad-hoc Release `.app`

## 复现证据

当前运行实例 `pid=87549` 在按住 Siri 键时记录：

```text
APPLE REMOTE HCI XPC phase=connecting service=present client_identifier_matches=true client_team_matches=false client_signature_adhoc=true
APPLE REMOTE HCI XPC phase=failed result=remote_proxy_error error_domain=NSCocoaErrorDomain error_code=4097
APPLE REMOTE AUDIO packet_stream phase=failed reason=hci_helper_unreachable_4097
APPLE REMOTE VOICE phase=pending result=audio_capture_not_ready
APPLE REMOTE VOICE phase=completed result=stopped ... audio_batches=0 audio_samples=0
```

按钮和触摸仍能工作，说明 HID/触摸链路不是本次故障点；失败发生在语音开始前的特权 HCI XPC 连接。

## 根因

安装在 `/Library/PrivilegedHelperTools/` 的 HCI Helper 使用 Team ID `L3QHLDRPAY` 的 Developer ID
要求校验客户端。测试 App 使用 ad-hoc 签名，日志明确显示 `client_team_matches=false` 和
`client_signature_adhoc=true`，因此 Helper 拒绝连接并返回 4097。随后 App 的有限退避重试全部失败，
正常结束流程没有丢音频，只是本次没有获得任何遥控器 PCM。

## 为什么之前测试会通过

自动化测试验证了事件、解析器、音频排空和包内 Helper 是否存在，但没有在已安装特权 Helper 的机器上，
用真实签名的 App 完成一次 Siri 键 → HCI XPC → PCM 的连续旅程。`verify-app.sh` 只在显式设置
`REQUIRE_DEVELOPER_ID_SIGNING=1` 时检查 Developer ID，因此 ad-hoc Siri Remote App 仍被误当成可测试资产。

## 修复与验证要求

1. `build-app.sh` 默认拒绝私有 Siri Remote 包的 ad-hoc Release 构建。
2. `verify-app.sh` 对包含 Siri Remote 的 App 强制检查 Developer ID Application 和 Team ID。
3. BuildSigningTests 固化该门禁，防止以后只验证“包能构建”而漏掉语音签名边界。
4. 使用本机 Developer ID `Developer ID Application: lei qian (L3QHLDRPAY)` 重新构建，并在同一台机器按住
   Siri 键验证 HCI 连接、遥控器 PCM、首字和松键尾字。

## 验收边界

在 Developer ID App 重新安装并实际按键前，只能确认签名门禁和自动化覆盖已补齐，不能宣称真机语音已恢复。
