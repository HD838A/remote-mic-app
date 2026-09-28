# 自定义组合快捷键缺少修饰键释放事件

## 复现与边界

用户把遥控器音量加、减设置为 Control+Tab、Control+Shift+Tab，在 Codex 中触发后停在最近会话列表，不能像实体键盘松开 Control 一样应用选择。此前自定义 Command+Tab 也有相似现象。用户截图和描述是现场证据；本次没有安装候选包或代替用户完成真实遥控器验收。

基线：`014d2b2f94cd59f8c9509a59d9c289f6642fe513`。

在改动产品代码前，注入无系统副作用的事件记录器执行 `KeyboardInjector.send(.customShortcut)`。Control+Tab 的复现日志是：

```text
REPRO control_tab_events=["pair:48:262144"]
Expectation failed: trace.contains("up:59")
Test run with 1 test in 1 suite failed
```

这证明调用链只提交带 Control 标志的 Tab 事件对，没有 Control 释放。原路径的 `SHORTCUT ACTION submitted ... standalone=false` 日志只记录主键和标志，不能证明修饰键释放或目标 App 已切换。未取得用户现场运行日志，不把用户可见根因当作已真机确认。

## 代码与根因

`KeyboardInjector.send` 的普通组合路径调用 `postKey`；该函数只构造主键 down/up，而且两个事件的 flags 相同。仅靠 flags 不能替代修饰键自身的变化事件。依赖松开修饰键完成选择的应用因此缺少结束信号；按下时即执行的快捷键不一定受影响。

## 修复

- 带修饰键的自定义快捷键转交 `ShortcutEventSequence`，依次按下修饰键、主键 down/up、逆序释放修饰键。
- 修饰键事件类型为 `flagsChanged`，包含累积的通用和左侧设备位；现有无侧别保存格式不迁移。
- 同一次操作使用私有 CGEventSource，并串行发送；每个边沿合并公开 HID 硬件状态，保留用户已按住或期间按下的物理修饰键。
- 失败停止继续按下，尝试主键和修饰键清理；释放提交失败仅重试一次。API 提交不等于目标应用收到，不声称系统释放一定成功。
- 日志用短生命周期 operation_id 关联请求和唯一终态，仅记录事件数量、阶段、耗时和清理状态；用户可见结果始终为 unknown。
- 无修饰单键、单独左右修饰键、语音键和内置持久 App 切换器保持原路径。

## 验证

回归覆盖 Control+Tab、Control+Shift+Tab、Command+Tab、全部修饰键累积/逆序释放、每个发送边沿的故障、清理再次失败、下一次操作恢复、实体键盘状态保留、权限拒绝、日志关联及现有单键/独立修饰键。

定向回归 127 tests / 2 suites 通过；完整 Swift 测试 591 tests / 46 suites 通过；仓库 Self Test 44 passed / 0 failed。`git diff --check`、仓库边界及治理检查通过。

完整命令和真实环境失败判定见 [测试手册](../Testing/CustomShortcutLifecycle.md)。这是事件协议层复现及修复验证，不是 WindowServer、Codex 或实体遥控器验收。

## 关联 PR

- [#361](https://github.com/HD838A/remote-mic-app/pull/361) 保留左右侧别并只为有侧别配置发送完整事件；其无侧别配置明确保留 flags-only 路径。本修复针对现有所有无侧别组合，二者整合时应统一注入路径并复测，不能直接覆盖其中一个。
- [#449](https://github.com/HD838A/remote-mic-app/pull/449) 是独立的一键切回 App 动作；本修复不新增动作或修改默认映射。
- 私有组合动作的绑定保存问题不属于本次修复。
