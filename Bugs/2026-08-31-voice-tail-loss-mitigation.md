# Issue #297：语音尾部截断缓解

## 复现与日志

88 个会话统计显示音频到达速率中位数约 89.8%，停止时 App 仅有 0–3 个待播放缓冲，且 `STREAM_STOP` 后没有晚到音频；缺口主要发生在遥控器发送队列。快速执行 `STOP → START` 的自动化复现还确认：旧停止 completion 会在新会话开始后松开 `.bluetooth` voice latch，并触发旧 drain 的 flush；修复前定向测试记录 `latch.isHeld == false`、旧 completion 执行计数为 1。

## 根因与边界

主缺口在固件/BLE 发送侧，Mac 无法补回未到达的音频；旧 App 侧仍在停止时先释放软件语音键，再等待播放排空，可能额外造成几十毫秒尾部风险。首次排空修复缺少停止 generation：新会话会复用仍持有的 `.bluetooth` owner，而旧 completion 随后会错误移除它；旧 drain 的 0.75 秒超时也会在 completion 前 flush 新会话缓冲。

## 修复

蓝牙语音停止路径改为先排空 App 播放队列，再释放软件语音键并结束会话；快速重启会递增 generation、取消旧 drain，旧 completion 即使迟到也不能松键或结束新会话。不增加固定等待，也不伪称可以修复遥控器侧 1–2 秒积压。

## 验证

- `swift test --filter ATVVProtocolTests`
- 自动化覆盖停止路径顺序和快速 `STOP → START` 时旧 completion 的失效、drain 取消与 voice latch 保持。
- 仍需固件支持或连接参数调整后，在 RC001/RC003 真机复测完整尾音；当前 PR 不能宣称解决硬件侧主缺口。
