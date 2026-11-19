# 切换器会话内绑定键被映射层吞掉，未绑定键没有可见反应

- 时间：2026-11-19
- 状态：候选修复，自动化通过，真机验收通过（2026-11-19）
- 影响范围：macOS Command-Tab 临时会话中的普通按键路由（HID 遥控器路径）
- 功能点：应用切换器、按键映射单击/双击/长按

## 错误证据

用户提案 [#1108](https://github.com/HD838A/remote-mic-app/issues/1108) 描述 v2.0.8 的现场行为：切换器（会话）显示期间再次按绑定键「界面不会有任何变化」，按其他键则「无反应」。

代码核对确认两处确定的行为缺口（`Sources/RemoteMic/HIDRemoteMonitor.swift`，修复前）：

1. 会话内只有「单击绑定为 `切换 App` 且没有配置双击、长按」的按键才会继续发送 Tab：

   ```swift
   let sessionTabAllowed = action == .appSwitcher
       && !recognizesDoubleClick && !recognizesLongPress
   ```

   只要同一个键还配置了双击或长按，会话内的单击就会落入 `default` 分支被 `swallowed`，既不发送 Tab，也不执行任何动作。

2. `TV` 在会话中无条件发送 Tab（`if appSwitcherSession.isActive, button == .tv`），不看它是否绑定为 `切换 App`；其余未绑定键则全部被吞掉，没有任何可见反应。

用户描述的「操作结束后又触发一次」未在本次复现中取得日志证据；它与映射层双击窗口和会话接管的时序重叠有关，按未验证现象记录，不在本次修复中断言。

## 根因

- 会话接管发生在按下路由层，但「该键的单击是否算作会话操作」仍读取映射层的双击/长按配置。映射层的配置越多，会话内的单击越容易被吞掉。
- `TV` 保留了历史特例：它在会话中的语义不来自绑定，而来自机型约定。
- 未绑定键采用「吞掉」策略，用户无法从按键行为判断会话是否仍在，也无法用一次按键退出。

## 最小修复

- 会话内按键语义完全由会话决定：`isSwitcherBinding = action == .appSwitcher`，不再参考双击/长按配置。
- 会话中只有绑定为 `切换 App` 的按键发送 Tab；`TV` 的历史特例删除。
- 未绑定键改为结束会话：先 `Escape` 再释放 `Command`（`finishAppSwitcherLifecycle`），并吞掉该键自身动作；日志改为 `HID APP SWITCHER ended_by button=… phase=session`。
- `performConfiguredAction` 在会话期间收到迟到动作时同样只结束会话并返回已消费，不再执行旧动作。

## 验证

自动化（`Tests/RemoteMicTests/RemoteButtonsTests.swift`）：

- `appSwitcherSessionUnboundKeyEndsSessionWithoutPerformingItsAction`：未绑定的 TV 结束会话，事件序列为 `⌘↓ / Tab↓ / Tab↑ / Esc↓ / Esc↑ / ⌘↑`，Escape 动作不执行。
- `appSwitcherSessionBindingsIgnoreDoubleAndLongTriggers`：单击绑定切换器、双击和长按绑定其他动作时，会话内第二次单击仍发送 Tab。
- `appSwitcherSessionTVAdvancesOnlyWhenBoundToSwitcher`：TV 绑定切换器时仍发送 Tab。
- `appSwitcherSessionEndsOnUnboundButtonsWithoutPerformingThem`（改写原「全部吞掉」用例）：音量键结束会话并释放 Command，原动作不执行。
- `appSwitcherSessionEndsOnDelayedActionFromBeforeSession`：会话开始前按下、双击窗口结束后才提交的动作只结束会话，不执行 `showDesktop`。

2026-11-19 用户在本机 Apple Silicon、公开测试包 build 391（source `723f9aa3`）上按 `Testing/AppSwitcherRemoteControl.md` 完成真机验收并确认通过。

## 验证边界

- 自动化只证明事件序列和修饰标志，不证明 WindowServer 中切换器高亮与最终前台 App；本轮真机已确认主路径。
- Intel Ventura 实机、多显示器、全屏空间与系统动画关闭未在本轮覆盖，按手册用例 9、14 另行验收。
- 绑定键同时配置双击时，进入会话仍要等 300ms 双击窗口结束；本次没有改变进入延迟。
- 「绑定切换器」按单击动作判断：只把切换器绑在双击或长按上的按键，会话中单击仍按未绑定键处理（结束会话）。
- 音量键在会话中结束会话，但原生音量事件仍由系统处理，音量会同时变化。
- 语音键不经过 `RemoteButton` 路由（系统 Fn 或遥控器语音 usage），本次不结束会话；提案里「语音键退出」需要单独的语音链路设计。
- 苹果遥控器走 `BridgeAppModel` 的独立会话路径，本次未改动其 `TV` 特例。

## 后续工作

- 长按绑定键确认、语音键退出、上下键 300ms 去抖均未纳入本次修复；原因、可选方案和「绑定按单击动作判断」的边界已写入 [应用切换器产品规范](../feature/app-switcher/PRODUCT_SPEC.md#明确不做)。
