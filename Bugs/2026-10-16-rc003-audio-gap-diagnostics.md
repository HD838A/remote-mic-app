# RC003 音频缺口诊断信息不足

## 现场问题

Build 300 的一次 RC003 会话持续约 36.55 秒。日志显示 29.85 秒解码样本。
用户反馈回眸文字缺少句尾。当前日志可以核对总计数，但不能定位缺口出现的时间段。

## 原有证据

- 接收回调、解码、路由、调度、播放和写入计数一致。
- `drop_after_stop=0`，写入失败为 0。
- 日志没有遥控器端采样计数，也没有无线包序号。
- `coverage_pct` 只按 Mac 回调处理时长计算。它不能证明无线到达率。

## 本次补充

每个音频 operation 现在记录有界的诊断字段：

- BLE generation、协议版本、codec、帧字节数和采样率。
- `STREAM_START`、同步、`STREAM_STOP` 的相对时间和当时回调、PCM 计数。
- 首次回调、停止前最后回调、停止后迟到回调的时间。
- 每秒窗口的接收字节、解码样本、路由样本、丢弃字节、部分帧、回调间隔和主线程延迟。
- 首 3 个窗口、末 8 个窗口和最低覆盖率 3 个窗口。中间窗口计数保留。
- 输出的 scheduled、played 和 pending 样本。共享输出时标为未知。
- MIC_CLOSE 写入结果、录音 writer 排队等待、写入耗时、首末写入时间和完成时间。
- 前一 operation、停止到下一次开始的间隔。
- `capture_samples=unknown` 和 `radio_sequence=unknown`。App 不伪造遥控器端数据。

日志不记录 PCM、设备身份、语音正文、包内容或第三方 App 内部状态。

## 下一次故障的判断顺序

1. `timeline` 中接收字节已经缺失：缺口在 Mac 回调之前，需用蓝牙抓包或遥控器端计数区分采集与无线传输。
2. 接收字节存在但 PCM 样本减少：检查帧边界、同步和解码路径。
3. PCM 存在但路由样本减少：检查音频缓冲和取消路径。
4. 路由存在但 scheduled 或 played 减少：检查虚拟音频队列。
5. played 完整但 writer 写入减少：检查录音 writer。
6. 所有样本完整但文字仍缺失：问题在外部语音工具或其文本观察边界。App 日志不会读取该工具内部数据。

## 验证

```sh
swift test --disable-keychain --filter 'ATVVAudioDiagnosticsTests|RecordingAsset'
git diff --check
```

31 项定向测试通过。测试覆盖控制事件、窗口时间线、输出计数和 writer 计时字段。
日志结构仍需要真实 RC003、真实虚拟音频设备和用户指定语音工具验收。
