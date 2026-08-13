# 持续麦克风抢占结束后的恢复顺序

## 复现

- 开启持续麦克风桥接，输入选择 DJI Mic Mini，输出选择 `MiRemoteV 2ch`。
- 触发 RC003、Nearby iOS 或 Web 手机语音，使持续输入被抢占。
- 结束高优先级语音并立即继续对 DJI Mic Mini 说话。
- 错误边界：原实现先恢复持续输入，再结束或清空高优先级语音会话；恢复后的首批 DJI buffer 可能被随后执行的 `endSession()` 清除。
- 正常边界：持续输入关闭时、没有恢复动作时以及高优先级语音开始时不触发此问题。

## 日志与代码结论

- 自动化状态机已证明抢占会生成 `stop → start`，但原有测试没有覆盖 `start` 相对于输出会话清理的先后顺序。
- `BridgeAppModel.swift` 的 RC003 停止和手机排空回调均在 `setContinuousInputPreemptor(..., active: false)` 之后调用输出会话结束逻辑。
- `setContinuousInputPreemptor(..., active: false)` 会同步恢复 AUHAL 输入；随后的 `audioOutput.endSession()` 会执行 `player.stop()` 和 `player.reset()`。

## 根因

恢复低优先级持续输入与清理高优先级输出会话的顺序相反，两个操作共享同一个 `VirtualAudioOutput` 播放节点。

## 修复

- RC003 正常停止：先完成高优先级会话结束，再解除抢占并恢复持续输入。
- RC003 断连：先结束会话，再解除抢占。
- Nearby/Web：先结束 Fn 与语音会话，再解除抢占。
- RC003 Fn 点按模式：等待输出排空和匹配的停止点按全部完成后，才解除抢占。
- RC003 与 Nearby/Web 使用先到先得门禁，禁止两路高优先级 PCM 同时写入。
- App 停止时先 teardown 持续输入，避免外部来源断开回调短暂重新启动麦克风。

## 验证

- 未注入私有组件的定向测试 52 项通过，组件缺失时启动失败关闭；
- 注入私有组件的 CoreAudio/虚拟音频/Fn 定向测试 20 项通过；
- 完整公开配置 `swift test` 225 项、21 个 suite 通过；
- 私有硬件模拟集成 22 项通过，`./scripts/test.sh` 42 项通过；
- 本轮没有构建 App、签名、公证、打包或发布。
- 原始真机用例仍需 DJI Mic Mini 与 RC003/Nearby/Web 分别执行，自动化不能证明真实蓝牙、TCC、射频和最终 ASR 行为。
