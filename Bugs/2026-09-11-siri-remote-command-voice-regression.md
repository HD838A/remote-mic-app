# 苹果遥控器 Command 语音键再次无法唤醒目标输入法

## 基本信息

- 时间：2026-09-11
- 状态：候选修复完成，等待真实遥控器与目标输入法验证
- 影响范围：macOS；语音键模式为左 Command 或右 Command；苹果遥控器 Type-C / Lightning 与其他复用软件语音键注入的来源
- 功能点：语音键即时按下/释放、左右 Command 侧别、第三方输入法唤醒
- 用户现象：无线麦收到语音键事件，但目标输入法没有出现电平图或没有进入收音；小米遥控器的既有路径正常。

## 复现

在其余新增测试 API 已可编译后，暂时只保留旧的 Command 注入实现并执行：

```text
swift test --disable-keychain --filter VoiceKeyModeTests
```

结果为 3 条失败：旧实现发送的 flags 为 `1048576`（通用 Command），左 Command 缺少设备侧标志 `8`，右 Command 缺少设备侧标志 `16`。完整苹果遥控器旅程 `appleRemoteCommandVoiceJourneyPostsOneSideSpecificDownAndMatchingUp` 同样在第一次 right Command down 失败。Fn 模式和释放事件空 flags 的既有断言未失败。

## 日志与代码证据

- `KeyboardInjector.setVoiceKeyPressed` 旧实现对左、右 Command 都只发送 `.maskCommand`。
- `VoiceKeyMode.keyCode` 虽然分别使用 55/54，但部分目标输入法依赖 `NX_DEVICELCMDKEYMASK` / `NX_DEVICERCMDKEYMASK` 判断物理侧别；只有虚拟键码和通用 Command 标志不足以稳定匹配。
- 旧日志 `VOICE KEY ... DOWN/UP` 只证明调用了合成事件路径，不能证明第三方输入法最终响应。
- 公开 PR #416 独立报告了相同缺口；本修复保留该贡献者的侧别标志方案，并在本轮完整回归中集成，不改写外部 fork 分支。

## 为什么旧测试会通过

旧 `VoiceKeyModeTests` 只断言 Command down 的 flags 精确等于 `.maskCommand`，等于把缺失的设备侧标志固化为“正确结果”。测试覆盖了键码、按下/释放配对和权限门禁，却没有验证目标输入法实际用于区分左右侧的标志，也没有覆盖“苹果遥控器 owner → right Command down/up”的连续旅程。因此构建、单元测试、签名或音频入队通过都发现不了目标输入法未被唤醒。

## 根因与修复

1. `VoiceKeyMode` 为 Fn、左 Command、右 Command 提供唯一的 `eventFlags`：Fn 使用 `.maskSecondaryFn`；左右 Command 同时包含 `.maskCommand` 和对应 `NX_DEVICE*CMDKEYMASK`。
2. `KeyboardInjector.setVoiceKeyPressed` 在 down 使用该模式 flags，up 继续发送空 flags，避免修饰键残留。
3. 新增苹果遥控器 owner 的完整 down/up 旅程测试，要求只发送一组正确侧别事件并最终释放 latch；项目自检同步检查两侧设备标志。
4. 成功日志改为 `result=event_submitted target_response=unknown`，明确区分系统事件已提交与第三方输入法最终响应。

## 验证

- 修复前定向测试：`VoiceKeyModeTests` 16 项中 2 项失败，共 3 条缺少侧别标志的断言，符合预期。
- 恢复修复后，语音键、指示器、本地化和电池策略四组定向测试共 67 项通过。
- 公开社区宿主完整 Swift 测试：473 项、39 suites 通过。
- 私有 Siri Remote Package：61 项、9 suites 通过。
- 注入 Siri Remote、组合动作、键位方案、会员和 Mac Remote 的完整宿主：514 项、44 suites 通过。
- 项目自检：44 项通过；清空所有私有 Package 环境变量后，社区 Release App 构建与 `verify-app.sh` 通过。
- 注入上述私有 Package 的 Release App 构建与 `verify-app.sh` 通过。该构建为本地 ad-hoc 集成验证，不作为用户交付包。

## 验收边界

自动化能够证明事件参数、生命周期和宿主接线，不能证明 CGEvent 已被目标输入法接受。最终必须在 Developer ID 签名包中分别用 Fn、左 Command、右 Command 和真实苹果遥控器验证：首次按下即可出现目标输入法电平、遥控器 PCM 到达 `MiRemoteV 2ch`、首字及时、松键尾字完整、连续会话不需要第二次才成功。
