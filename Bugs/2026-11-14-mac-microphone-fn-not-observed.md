# Mac 麦克风在豆包同时使用 Fn 时不开始采集

状态：代码修复完成，等待真实豆包、AirPods 和连续会话验收。

## 现象

用户选择“用所选麦克风说话”后，界面显示按钮“停用所选麦克风说话”和状态“待命”。按键盘 Fn 时，系统和豆包的麦克风提示出现，但豆包电平不波动、没有文字；Mac 内置麦克风和 AirPods 都无声。

## 证据

`~/Library/Logs/RemoteMic/runtime.log` 的对应会话：

- `MAC MICROPHONE KEY_MONITOR phase=started result=listening voice_key=fn event_passthrough=true`
- `MAC MICROPHONE operation_id=2 phase=armed result=waiting_for_voice_key capture_running=false`
- 到 `phase=completed result=failed completion=forced reason=app_stop` 为止，没有 `MAC MICROPHONE phase=voice_key`，也没有 `MAC MICROPHONE CAPTURE phase=started`。
- 同一日志中的遥控器音频会话有正常 decoded/routed/played 样本，说明虚拟输出到豆包的链路本身可用。

结论：SayAll 的 Fn 回调没有收到物理边沿，采集从未开始。Mac 麦克风和 AirPods 同时无声是同一个原因；不能用设备选择解释。

## 触发条件

- 豆包等第三方语音工具也使用 Fn 作为语音快捷键。
- SayAll 的 Mac 麦克风音源已启用，监听已启动。
- 用户物理按下 Fn。

## 排查

1. [MacMicrophoneVoiceKeyMonitor.swift](../Sources/RemoteMic/MacMicrophoneVoiceKeyMonitor.swift) 原来使用 `.cgSessionEventTap` + `.tailAppendEventTap` + `.listenOnly`。尾部只读 tap 位于其他 tap 之后；如果更早的 active tap 消费 Fn，SayAll 收不到边沿。
2. [MacMicrophoneSessionController.swift](../Sources/RemoteMic/MacMicrophoneSessionController.swift) 只有 `handleVoiceKey` 收到边沿后才开始采集。日志没有 `phase=voice_key`，所以后续权限、设备、采集代码都没有执行。
3. 应用自己的 `KeyboardEventSuppressor` 是头部 active tap，但 `descriptor` 不处理 `flagsChanged`，Fn 会被放行；仍不能排除豆包或其他第三方 active tap 在尾部只读 tap 之前消费 Fn。
4. 远程桌面或非标准键盘可能根本不把 Fn 作为 `keyCode=63` 的 `flagsChanged` 边沿转发。这属于同一现象的另一触发路径，需要真实环境区分。

## 修复

- Fn 观察改为分层只读监听：
  1. 优先尝试 HID 级 `.cghidEventTap` + `.headInsertEventTap` + `.listenOnly`；
  2. HID tap 不可用时回退到会话级 `.cgSessionEventTap` + `.headInsertEventTap` + `.listenOnly`；
  3. 两者都失败才报告监听失败。
- 两种 tap 都只读，不吞键、不修改事件，不额外发送 Fn 或其他按键。
- 日志增加 `tap=hid_head` 或 `tap=session_head`，便于区分实际生效的观察层。
- UI 文案和选择器行为的改动因未先完成设计稿评审已撤回；本记录只覆盖 Fn 监听修复。

## 验证

- 自动化：`swift test --disable-keychain` 1423 项、104 个 suite 通过；`MacMicrophoneInputTests|LocalizationTests` 31 项、2 个 suite 通过。
- 本地检查：`SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh` 48 项通过；`scripts/verify-localizations.sh`、`scripts/verify-repository-governance.sh` 和 `git diff --check` 通过。
- 本机包：`scripts/package-local-test-app.sh` 构建并安装 `~/Applications/SayAll.app`，Build 364，source `822014ac`，dirty=true，已启动。
- 真实设备：待验证豆包同时使用 Fn、内置麦克风、AirPods、快速按下/释放、连续 20 次会话、遥控器主路径和 Jump Desktop/远程键盘边界。

## 边界

- 单元测试不能创建真实 CGEvent tap，也不能证明豆包、AirPods 或远程键盘行为。
- HID 级 tap 是否可用取决于系统权限和运行环境；不可用时必须记录回退，不得假装监听成功。
- 在本机包和真实豆包流程通过前，本问题保持候选，不得标记兼容或发布完成。
