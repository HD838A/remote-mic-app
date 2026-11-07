# G9N9N 正常结束后第二次语音不启动

## 触发与现场证据

用户使用 Mac 焦点、Deskflow 和豆包 Fn 按住模式。build 19 真正重连 G9 后，
第一句“第一句测试”正常上屏，松开等待两秒后第二句无豆包浮窗、无文字。
第一句 09:57:28–31 的日志有新 generation、24,576 个样本、正常排空和 Fn 抬起；
之后没有新的 voice started。旧日志的成功不能覆盖第二次的失败。

HCI 先前首次收到 ATVV 控制通知为4字节，与该样机直接 STREAM_START 格式一致。
本记录不保存原始蓝牙流、音频或输入内容，也不把诊断计数当最终文字证据。

## 可重复的根因实验

宿主 `endVoiceSessionIfNeeded` 在正常排空及使用量/转写清理后也调用
`notifyHostVoiceSessionEnded`，公开桥转至 `G9N9NVoiceSession.cancel`。
原 cancel 无论是否还有活动会话都会将 cancelled 置真；正常 STOP 已将 active 置假。
下一次直接 STREAM_START（没有额外 MIC_OPEN request）因此被当取消后的迟到开始拒绝。

自动化 `normalStopThenHostCleanupAllowsTheNextExplicitStreamStart` 复现真实顺序：
STREAM_START → PCM → STOP → 正常 drain → 宿主 cleanup → 新 session STREAM_START → PCM。
旧实现第二次未启动，回归测试稳定失败，输出留在本地 `g9-second-session-before.log`。
它与“重连只第一句成功”的现场一致，但仍需修复包实机确认。

## 最小修复与验证边界

cancel 在已经没有活动传输时保持无操作；不把正常结束变成取消。
活动会话的真正取消仍置 cancelled、发送关闭、拒绝迟到 START/PCM，直到新 MIC_OPEN request。
不从任意迟到音频隐式启动，不修改豆包配置、语音键手势、原生权限或网络路由。

- 修复前：新回归测试失败，第二次 active=false，未收到新 PCM。
- 修复后：原失败测试及相关88项/4套件通过；公开全量1,288项/93套件通过。主动取消后的迟到 START/PCM 拒绝用例保留并通过。治理、相对链接及diff检查通过。
- 实机：待本地修复包连续两句、结束后再次开始及尾字/正常排空复验。
- 连接页重连入口的独立缺陷见 [重连记录](2026-11-06-g9n9n-reconnect-target.md)。


## 正常结束调用链清理

按用户“彻底清理拦截”的要求，进一步将公共 G9 的传输取消从共享使用量/转写收尾移出。
正常 STOP 自然排空后只完成宿主收尾；显式异常/host stop 才由 G9 自身 owner 通知传输取消。
先清除宿主活动标记，再通知传输，避免同步 stop 回调重入同一活动会话。
私有 toggle 后端维持原有 host-latch 完成合同；其他来源正常结束不再触碰公共 G9 取消状态。

幂等 cancel 保留作传输接口的正常约束，而非依赖它吸收每次正常收尾的错误取消调用。
此清理的相关语音/Chromecast/G9/虚拟音频回归 278 项 / 37 套件通过。
build20 已观测连续三次真实开始/正常停止，但最终豆包文字和用户所报右键效果仍需单独确认。
