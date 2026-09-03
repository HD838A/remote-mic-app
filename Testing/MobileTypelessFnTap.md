# 移动语音 Typeless Fn 点按测试手册

## 适用版本与分支

- 开发分支：`codex/mobile-typeless-fn-tap-main`
- 适用平台：macOS 14 及以上；当前兼容的 iPhone、Apple Watch 和 Web 遥控
- 状态：自动化与 Release 构建通过，等待官方签名、公证构建真机验收

## 测试前准备

1. 安装官方 Developer ID 签名、公证并 staple 的候选 App，不使用 ad-hoc 或未公证包。
2. 确认 MiRemoteV 2ch 可用，并让 Typeless 使用同一麦克风。
3. 授予辅助功能、输入监控及所需连接权限，选择 Fn/地球键并开启“语音键模拟 Fn 点按”。
4. 打开 Typeless，让普通可编辑输入框获得焦点。
5. 分别准备已授权的 iPhone、Apple Watch 和 Web 会话。
6. 记录 Mac、客户端、Typeless 版本及每个用例的 UTC 开始和结束时间。

## 用例一：三种移动来源正常语音

分别从 iPhone、Apple Watch 和 Web 开始语音，说 5～10 秒后停止，每种来源执行三次。

预期：每次只短按一次 Fn 启动 Typeless，音频排空后只短按一次 Fn 停止；首字尾字完整并产生一条文字。日志每次包含两组 `MOBILE VOICE FN TAP DOWN/UP posted`，`audio_summary` 有非零样本且 `enqueue_failures=0`。

失败：整段保持 Fn、Typeless 未启动、重复启停、首次无效、文字进入错误输入框、首尾缺字或 Fn 卡住。

## 用例二：极短语音和快速重启

1. 开始后约 1 秒立即停止。
2. 停止后立即再次开始，说 3～5 秒后停止。
3. 每种移动来源重复三轮。

预期：极短会话仍完成开始点按、完整音频和停止点按；第二次开始等待前一会话真正结束，不返回长期占用，不把两段音频合并。

失败：短会话丢失、上一段进入下一段、第二段永久 busy、出现多余 Fn 边沿或需要重启 App。

## 用例三：目标准备与取消

分别测试目标已聚焦、目标在后台、目标输入框失焦，以及等待过程中取消或断开移动来源。

预期：目标就绪后才执行第一次 Fn 点按；等待期间音频进入有限 pre-roll；取消后不向旧输入框发送 Fn，后续新会话可以正常开始。

失败：首次音频丢失、文字进入旧窗口、取消后仍发送点按、Fn 残留或后续会话一直占用。

## 用例四：关闭 Fn 点按的稳定基线

关闭“语音键模拟 Fn 点按”，分别使用 Fn、左 Command、右 Command 长按目标完成移动语音。

预期：开始时按下当前语音键，整段会话保持，尾音排空后释放；不会额外执行 Typeless 双点按。客户端协议、PCM、增益和来源互斥不变。

失败：关闭后仍执行两次点按、Command 模式被改成 Fn、停止前释放按键或音频未排空。

## 用例五：异常清理

在开始等待、录音中和停止排空期间分别撤销辅助功能权限、断开客户端或退出 App。

预期：已按下的 Fn/Command 最终释放；失败日志明确，下一次获得权限或重新连接后可恢复，不需要重启 Mac。

失败：系统修饰键保持按下、Typeless 长期保持录音、移动来源永久 busy 或迟到停止影响新会话。

## 稳定功能回归

- 实体 RC001/RC003 的按下/释放语音生命周期和实体 Typeless Fn 点按不变。
- iPhone、Apple Watch、Web 普通按键、授权、来源互斥和断线重连不变。
- MiRemoteV 保持现有 16 kHz PCM、声道、增益及录音归档行为。
- 关闭 Fn 点按后，豆包、微信输入法等长按工具继续使用既有路径。

## 日志收集

收集 `~/Library/Logs/RemoteMic/runtime.log` 中标记时间段，重点核对：

```text
MOBILE VOICE FN TAP DOWN posted
MOBILE VOICE FN TAP UP posted
MOBILE VOICE started source=...
MOBILE VOICE audio_summary source=...
MOBILE VOICE stopped source=...
MOBILE VOICE restart_deferred
MOBILE VOICE restart_completed
```

日志不得包含音频内容、识别文字、账号、地址、校验码或身份指纹。

## 自动化、代理与用户实测边界

- 自动化覆盖 Tap/Hold 选择、pre-roll、尾音排空、极短会话、点按失败、失败回退先于延迟重启、Bridge 接线和退出清理。
- 验证结果：移动会话 8 项、受影响稳定基线 42 项、全量 `swift test` 446 项、`./scripts/test.sh` 44 项及 `swift build -c release` 全部通过；仅有仓库既有 macOS API 弃用警告。
- 构建和单元测试不能证明 macOS 最终事件投递、Typeless 响应、网络链路或文字质量。
- iPhone、Apple Watch、Web、MiRemoteV、Typeless 和真实权限历史必须使用官方签名、公证候选进行用户实测；未执行前不得标记真机通过。
