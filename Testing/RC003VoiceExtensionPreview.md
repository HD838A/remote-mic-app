# RC003 长语音续流测试包

适用版本：`codex/rc003-voice-extension-test-20260826`，测试包版本 `1.9.15 (155)`。这是仅用于验证“遥控器语音输入是否能跨越物理语音段限制”的实验包，不代表正式版本已支持无限时长录音。

## 测试前准备

1. 使用 macOS 14 或更高版本的 Apple Silicon Mac。
2. 已完成无线麦SayAll.app 首次配置，RC003 已通过蓝牙连接并可进行普通语音输入。
3. 已授予应用蓝牙、辅助功能和输入监控权限；目标输入框已打开并可接受语音输入。
4. 退出正在运行的 SayAll/RemoteMic 实例，避免与测试包的蓝牙会话冲突。

## 启动

解压测试包后，双击同目录的 `launch_rc003_voice_extension_test.command`，或直接双击测试 App。测试 App 已在自身 `Info.plist` 中启用实验模式，不需要任何启动参数。

```bash
open -n "SayAll-RC003-VoiceExtension-Test.app"
```

首次打开如被 macOS 拦截，请在 Finder 中右键应用选择“打开”，并确认允许访问已有权限。当前本地测试包已使用 Developer ID 签名，但未提交 Apple 公证；Gatekeeper 可能因此显示“无法验证开发者”，这不代表续流逻辑失败。关于页面最底部会显示“测试长时间语音功能”，启动后沿用本机现有配置。

## 核心用例

1. 将光标放入目标输入框。
2. 按住 RC003 语音键开始说话，先持续说满 10 秒以上，确认目标输入框已有文字或语音服务已有输入。
3. 继续保持语音测试约 90 秒。遥控器固件可能在中途产生一次或多次物理 `STREAM_STOP`；测试包会自动重新发送 `MIC_OPEN`，不需要再次按键。
4. 观察在物理段切换后，目标输入是否仍属于同一次连续语音输入，且没有出现第二次独立的 Fn/语音会话。
5. 测试包最多运行 120 秒，到时自动发送 `MIC_CLOSE` 并结束会话。也可以直接退出应用中止测试。

## 通过标准

- 日志出现 `RC003 EXTENSION physical_stop reopen_requested=true`。
- 随后日志出现 `RC003 EXTENSION physical_segment_reopened`，并且出现 `RC003 EXTENSION AUDIO_READY`。
- 每约 8 秒出现 `RC003 EXTENSION MIC_EXTEND sent`；这些日志只能在真实解码音频到达后出现。
- 物理段切换后文字仍继续进入原目标输入框，未产生第二个独立语音会话。

## 失败判定

- `reopen_requested=false`、`reopen_timeout` 或 `reopen_rejected`。
- 只有 `STREAM_START` 日志却没有 `RC003 EXTENSION AUDIO_READY`，或重开后没有新的音频数据。
- `MIC_EXTEND failed`、蓝牙断连，或 120 秒前会话被错误结束。
- 目标输入框出现重复 Fn、第二个语音会话、输入中断或崩溃。

## 日志收集

测试结束后执行：

```bash
log show --last 10m --style compact --predicate 'process == "RemoteMic"' \
  | grep -E 'RC003 EXTENSION|ATVV STREAM|ATVV AUDIO|VOICE FN TAP'
```

请同时记录：遥控器型号、macOS 版本、测试开始时间、第一次物理 STOP 的大致时间，以及目标输入框是否持续收到文字。

## 验证边界

- 当前自动化验证只覆盖编译和代码路径；它不能模拟 RC003 固件是否接受 `MIC_EXTEND`，也不能证明真实音频特征在主机重开后一定恢复。
- “续流成功”必须以 `AUDIO_READY` 和目标输入框继续接收文字为准；仅看到控制层 `STREAM_START` 不算通过。
- 本实验包有 120 秒安全上限，未实现正式产品的用户停止交互、持久化配置或 UI 提示。
