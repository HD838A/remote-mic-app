# ChatGPT 翻页连续触发时后续滚动不明显

- 时间：2026-08-23
- 状态：候选修复完成，等待 PR 合入后的真实环境复验
- 影响范围：ChatGPT / Codex 应用专属翻页动作
- 功能点：目标窗口滚轮事件、ChatGPT 长回复翻页
- 简单描述：连续触发翻页动作时，第一次滚动明显，后续动作需要等待约 1--2 秒才稳定响应。

## 复现与日志

1. 将遥控器左键或右键绑定为 ChatGPT 上一页或下一页。
2. 打开 ChatGPT 长回复并保持窗口在最前面。
3. 连续触发翻页动作。
4. 用户现场观察到第一次翻页有效，后续动作在短间隔内不明显；每次间隔约 1--2 秒后可以继续翻页。

运行日志确认遥控器输入没有丢失：每次动作均进入 `codexPageUp` 或 `codexPageDown`，并发出完整的 3 个滚轮事件。因此问题边界位于合成滚轮事件到 ChatGPT 页面滚动容器的处理阶段，而不是按键映射或 HID 去重。

## 根因假设

ChatGPT 的 WebKit/Chromium 滚动层可能将未明确标记的合成滚轮事件按连续手势合并处理，短时间内的后续事件因此不一定产生独立的页面滚动。

## 修复

在 ChatGPT 翻页专用滚轮事件中显式设置 `scrollWheelEventIsContinuous = 0`，将事件标记为离散鼠标滚轮事件。保留窗口中心定位、`wheelCount = 2` 和 10--15ms 的事件间隔；普通滚轮动作和输入框聚焦逻辑不变。

## 验证

- `git diff --check`：通过。
- `xcrun swiftc -parse Sources/RemoteMic/KeyboardInjector.swift Tests/RemoteMicTests/RemoteButtonsTests.swift`：通过。
- `scripts/test.sh`：42 项通过，0 项失败。
- 已重新打包、安装并启动 SayAll；日志确认 RC003 已连接、输入监控和辅助功能权限有效。
- 真实 ChatGPT 页面仍需在 PR 合入后的版本中按“连续按 5 次、每次间隔 1--2 秒”复验。自动化事件投递日志不能替代页面可见滚动结果。
