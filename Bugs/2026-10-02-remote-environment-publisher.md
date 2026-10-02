# 遥控测试免检切换环境的订阅值

主线接入审查发现：订阅 Published 环境变化时丢弃新值并读取原属性，可能漏掉切 production 时停止测试会话。

复现：Combine 最小例由 staging 赋为 production，sink 观察到 `emitted=production stored=staging`。无异步 receive，属性在发布后才更新。

假设核对：旧值读取已证实；异步投递假设被无 receive 的最小例否定；私有适配器仅拒绝新请求，不能替代宿主停止既有 WebSocket。

最小修复：直接使用 sink 的 environment 新值，保留既有 generation、幂等键清除及 client.stop。既有回归合同检查新值 guard，防止退回读取旧属性。

验证按 PR 记录公开/私有消费者完整测试、构建和 UI；真实环境切换、扫码及音频仍与自动化分开，不据此宣称真机验收。
