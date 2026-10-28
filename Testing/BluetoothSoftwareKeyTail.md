# Bluetooth 软件语音键尾音候选验证

## 适用范围

Bluetooth 软件按住语音键候选，针对普通 RC001/RC003 软件 Command/Option 按住路径。
本地源码候选已能构建开发 App，但没有正式签名/公证的安装包。
用户安装包仍须按原发布规则完成签名和公证；不能把本手册当作安装授权。

## 自动化

在具备完整 Xcode/Swift Testing 支持的环境运行：

```sh
swift test --disable-keychain --filter VoiceKeyReleaseDrainTests
swift test --disable-keychain --filter VoiceFunctionKeyLatchTests
swift test --disable-keychain --filter VirtualAudioConnectionLifecycleTests
swift test --disable-keychain --filter CoreVoiceInputJourneyTests
```

不得设置 `SAYALL_TEST_MUTATE_VIRTUAL_AUDIO_LEVEL`，本次不需要修改真实设备属性。
本机 Xcode 27.1 下完整测试目标编译通过，103 项相关测试通过；未执行全仓测试。

## 真机（待完成）

保持同一系统输入、同一遥控器、同一目标工具和原有快捷键，不以摄像头麦克风成功替代遥控器验收。
由用户执行录音和转写确认，代理不自动录环境音或点击第三方提交。

1. 使用旧版说带明确末尾标记的短句与约 20 秒长句，各 5 次，说完立即松键，记录末尾标记是否完整。
2. 经单独批准并取得合规候选包后，用候选重复相同句子、同样操作，各 5 次；不刻意多按三秒。
3. 连续快速按下两次，共 5 组，确认第二句首字与第一句尾字完整，旧回调不结束新录音。
4. 一次极短按下/释放，确认无固定首响等待和残留修饰键；再正常说一句确认恢复。
5. 用户在收尾时主动断开设备或退出 SayAll，确认键释放且重新启动后的第一句可用。
6. 分别回归硬件 Fn 与已有 Fn Tap，确认原触发语义未改变，不新增双击或长按阈值。

## 日志与失败判定

同一 operation 应出现 `key_release phase=waiting_for_playback`、`AUDIO DRAIN` 完成，
再出现软件键 UP。空队列可以立即完成；不得为满足测试而添加固定等待。
快速再次按下应记录 `reason=rapid_repress result=continued_hold`，旧排空回调不得释放新会话。
超时/断连必须标记 `completion=forced`，不能作为正常尾音通过。

通过需同时满足用户确认尾字完整、无首字回退、按键无残留、正常路径没有音频中断。
单看非零波形、入队成功或 dataPlayedBack 不能判定 ASR 完整。
如果立即松键仍缺少秒级尾部，而候选已排空后释放，应继续按现有 ATVV 诊断区分
接收前缺口、解码/路由缺口、设备读写与外部消费者边界；不得声称所有尾音缺失均已解决。
