# Watch BLE 音频积压阻塞 iPhone 语音

- 时间：2026-08-15
- 状态：候选修复完成，等待实际测试 Mac 与真实设备验收
- 影响范围：Mac `1.8.23`、iOS / Watch `0.8.12 (7)`
- 功能点：移动语音会话归属、Watch BLE 音频接收、服务端错误分类
- 简单描述：Watch 已连接并采集音频，但停止控制被大量 BLE 音频包阻塞；Mac 长时间保留移动语音占用，导致 Watch 无最终响应且 iPhone 后续语音被拒绝。
- 原始记录：实际测试 Mac `runtime.log` 与 iPhone 导出的合并诊断日志；敏感设备信息不写入仓库。

## Observations

- 现场 Mac 输入监控与辅助功能权限均正常，虚拟麦克风输出已就绪；同一时段实体遥控器语音正常。
- Watch 9.4 秒产生 179 个 50ms 音频帧，压缩后每帧 404 字节并拆成 3 个 BLE 包。
- Watch 在 `18:20:55` 结束录音，但 Mac 约到 `18:21:23` 才处理停止，延迟约 28 秒。
- 旧 Watch 发送端对全部音频与控制包统一使用 `.withResponse` 且严格串行，停止排在数百个音频分片之后。
- Mac 主仓使用同一个 `.nearby` 标记 iPhone 和 Watch；一个来源的延迟停止无法与另一个来源隔离。
- 服务端只返回统一的语音输出失败，iOS 因此向用户显示错误的辅助功能/虚拟麦克风建议。

## Hypotheses

### H1：Watch BLE FIFO 积压导致实时音频和停止延迟（ROOT HYPOTHESIS）

- Supports：停止延迟、音频分片数量和逐包确认队列完全对应。
- Conflicts：无。
- Test：Watch 端控制与音频分队列、限制实时窗口后，停止必须优先且旧音频必须被清除。

### H2：Mac 权限或虚拟麦克风失败

- Supports：客户端显示了该类提示。
- Conflicts：现场日志和实体遥控器稳定基线均否定。
- Test：同一时段检查权限、输出状态和实体遥控器语音；已否定。

### H3：Mac 没有收到 Watch 的开始或音频

- Supports：最终第三方语音工具无响应。
- Conflicts：Mac 最终处理了延迟停止，Watch 日志持续产生并排队音频。
- Test：按事件顺序核对 Watch 录音和 Mac 会话状态；主要问题是传输时序而非采集缺失。

### H4：iPhone 是独立故障

- Supports：iPhone 后续也无法语音。
- Conflicts：iPhone 连接和遥控正常，失败发生在 Watch 长时间占用之后。
- Test：让 Mac 分别跟踪 iPhone 与 Watch 来源，并拒绝非当前来源的停止。

## Experiment

- 私有连接组件新增结构化开始结果：成功、通道占用、输出不可用；旧 Bool 回调保留兼容。
- Mac 主仓新增来源隔离回归，要求 iPhone 使用 `.nearbyPhone`、Watch 使用 `.nearbyWatch`，并分别绑定开始、音频和停止。
- Watch 写缓冲测试证明停止优先、音频窗口有上限；两端完整自动化通过。

## Root Cause

Watch BLE 发送端用无上限逐包确认 FIFO 传输实时音频，导致停止控制严重延迟；Mac 又将 iPhone 和 Watch 合并为同一语音来源，使延迟停止和通道占用跨设备传播。

## Fix

- Mac 分别跟踪 iPhone、Watch 和 Web 的移动语音来源；只有当前来源能够发送音频或停止自己的会话。
- 已占用时返回稳定的 `voice_busy`，音频输出或系统语音键未就绪时返回 `voice_output_unavailable`；旧客户端收到未知 detail 时仍安全降级。
- 新增脱敏的移动语音开始、拒绝、停止和来源不匹配日志，不记录音频、设备身份或确认码。
- 固定 `sayall-mac-remote` 到包含兼容结果 API 的 revision；Web 继续使用原 Bool 回调，不改变协议与行为。

## Validation

- `sayall-mac-remote swift test`：18 项通过。
- Mac 主仓 `swift test`：220 项、18 个 suite 通过；`swift build` 通过。
- iOS/Watch iPhone 12 Simulator：69 项通过，包含 Watch 实时写缓冲与用户提示。
- 未完成真实 Watch BLE 吞吐、停止实际到达延迟、Watch 停止后立即使用 iPhone、MiRemoteV 2ch 输出、豆包响应和实体遥控器 RC003 基线；开发代理当前 Mac 不是用户的实际测试 Mac，不能替代该验收。
