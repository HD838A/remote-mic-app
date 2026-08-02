# RC003 无按键持续收音研究

- 研究日期：2026-08-01
- 研究对象：小米蓝牙遥控器 2 Pro / RC003-MS
- 核心问题：遥控器已与 Mac 连接后，能否完全不按语音键，由 App 主动打开麦克风并持续接收音频

## 结论

**需要修正之前“RC003 硬件已确认不能无按键收音”的结论。现有证据只能确认正常产品路径必须按住语音键，不能确认主机主动开麦失败。**

当前最准确的判断是：

1. **正常使用路径不支持。** 小米官方只宣传“独立的语音按键”“近场语音”“一键唤醒”；本项目真机日志也显示按下后开始音频、松开后立即停止。
2. **ATVV 协议层面支持主机主动开麦。** Infineon 官方参考固件使用与 RC003 相同的 ATVV UUID，并明确把 `MIC_OPEN (0x0C)`、`MIC_CLOSE (0x0D)`、`MIC_EXTEND (0x0E)` 定义为主机到遥控器的命令。其命令处理器收到 `MIC_OPEN` 后直接启动音频，不要求代码先检查语音键是否按下。
3. **持续时间可能受硬件超时限制。** 同一官方参考固件包含 15 秒典型音频超时，ATVV v1.0 则定义了 `MIC_EXTEND`。这说明长时间会话需要续期设计，不能只发送一次 `MIC_OPEN` 后假定会无限传输。
4. **RC003 本机仍缺少决定性实验。** 当前 App 从来没有在无 `START_SEARCH (0x08)` 的情况下主动写 `MIC_OPEN`，所以已有测试无法回答 RC003 是否接受该命令，也无法回答 `MIC_EXTEND` 是否能维持会话。
5. **最终可行性暂定为“协议可行、设备待验证”。** 短时无按键开麦值得测试；无限或全天持续收音不能在测试前承诺。即使协议可用，300mAh 电池、休眠、蓝牙稳定性、隐私提示和实体静音仍可能使它不适合作为正式常开麦克风。

## 官方证据

### 小米官方产品资料

[小米蓝牙遥控器 2 Pro 产品页](https://www.mi.com/xiaomi-bluetooth-remote-2-pro)确认：

- 型号为 RC003-MS；
- 使用蓝牙连接，内置 300mAh 可充电电池；
- 语音能力描述为“独立的语音按键，集成近场语音，一键调用人工智能语音”。

页面没有声明常开麦克风、免按键收音或后台持续监听。因此它能证明产品默认交互依赖语音键，但不能证明固件拒绝主机的 ATVV 开麦命令。

[Bluetooth SIG Listing 293975](https://qualification.bluetooth.com/ListingDetails/293975)由 Xiaomi Inc. 提交，产品列表包含 RC003-MS，营销名称为 Bluetooth Voice Remote。该记录只证明蓝牙产品身份和采用的设计，不公开 ATVV 状态机、配对后的麦克风策略或持续收音能力。

### Infineon 官方 ATVV 参考固件

Infineon 官方的 [CYW20829 Voice Remote Reference Solution](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote)使用相同 ATVV 服务 UUID。其固定提交中的命令定义明确标注方向：

- [`MIC_OPEN (0x0C)`：TV/主机 → 遥控器](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote/blob/b2b7dcb046ca2be022dcd0dc931699f670a35c98/app_bt/app_bt_hid_atv.h#L110-L121)
- [`MIC_CLOSE (0x0D)`：TV/主机 → 遥控器](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote/blob/b2b7dcb046ca2be022dcd0dc931699f670a35c98/app_bt/app_bt_hid_atv.h#L110-L121)
- [`MIC_EXTEND (0x0E)`：TV/主机 → 遥控器，ATVV 1.0](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote/blob/b2b7dcb046ca2be022dcd0dc931699f670a35c98/app_bt/app_bt_hid_atv.h#L110-L121)

其 [`MIC_OPEN` 处理代码](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote/blob/b2b7dcb046ca2be022dcd0dc931699f670a35c98/app_bt/app_bt_hid_atv.c#L271-L305)在通知已启用时直接调用 `app_start_adpcm_transfer()`，随后发送 `AUDIO_START`。这里没有要求语音键处于按下状态。

同一参考实现还定义了[典型 15 秒音频超时](https://github.com/Infineon/mtb-example-btstack-freertos-cyw20829-voice-remote/blob/b2b7dcb046ca2be022dcd0dc931699f670a35c98/app_bt/app_bt_hid_atv.h#L150-L158)。这与 `MIC_EXTEND` 一起说明 ATVV 设计考虑了主机未及时关闭麦克风时的电池保护和会话续期。

这组证据能证明“协议允许主机主动发起和延长会话”，但不能证明小米使用的具体固件完整实现了同样行为。

## 当前仓库和真机证据

当前协议实现已经具备主机命令：

- `ATVVProtocol.microphoneOpen()` 对 v1.0 生成 `0x0C 0x00`；
- `ATVVProtocol.microphoneClose()` 对 v1.0 生成 `0x0D + sessionID`；
- RC003 能力日志为 `version=0x0100`、16kHz codec、120 字节帧。

但 `XiaomiBluetoothBridge` 当前只在收到遥控器的 `START_SEARCH (0x08)` 后发送 `MIC_OPEN`。现有真机日志中的所有会话都是：

```text
VOICE FN HARDWARE DOWN
ATVV STREAM START
VOICE FN HARDWARE UP
ATVV STREAM STOP
```

因此，现有日志只验证了按键路径，不能用于否定主机主动开麦路径。

仓库的 ATVV v1.0 能力解析测试样本包含 `interaction = 0x03`。公开的第三方 ATVV 实现通常把 `0x03` 解释为 Hold-to-Talk；这与 RC003 松开按键即停止相符。不过交互模式描述的是按键发起的会话行为，并不自动等于禁止另一条由 `MIC_OPEN` 发起的主机会话。

## 第三方交叉验证

[ATVVoice](https://github.com/b0o/ATVVoice)是第三方 Linux 实现，不是 Google、小米或 Bluetooth SIG 官方材料，不能单独作为 RC003 结论。但它提供了有价值的交叉验证：

- 对 ATVV 1.0 把 `0x00 / 0x01 / 0x03` 解释为 OnRequest / Press-to-Talk / Hold-to-Talk；
- 提供外部命令直接发送 `MIC_OPEN`；
- 提供“有音频消费者时自动开麦”的 mic-on-demand 模式；
- v1.0 使用 `MIC_EXTEND` 作为 keepalive，防止音频传输超时。

这说明主机主动开麦并不是本项目臆造的协议用法，但是否适用于 RC003 仍由真机结果决定。

## 仍未解决的问题

1. RC003 在没有先发送 `START_SEARCH` 时，收到 `0x0C 0x00` 会返回 `AUDIO_START`、错误码，还是完全无响应？
2. 如果成功，音频是否会在 15～60 秒后因硬件传输超时停止？
3. RC003 是否实现 `MIC_EXTEND (0x0E)`，需要多久发送一次？
4. 遥控器进入省电休眠后，主机命令能否唤醒它，还是仍需按键唤醒？
5. 长时间保持 BLE 高吞吐和麦克风工作时，300mAh 电池能持续多久，温度和连接稳定性如何？
6. 无按键录音时遥控器是否有可见指示；如果没有，产品上如何满足隐私告知和快速静音要求？

## 建议的受控真机实验

这一步会向真实遥控器写命令，尚未执行。建议单独获得用户授权后再做：

1. 保持 RC003 已连接且 ATVV 能力协商完成，不按任何键；
2. 记录完整原始 control notification；
3. 仅发送一次 v1.0 `MIC_OPEN = 0x0C 0x00`；
4. 最多等待 5 秒，观察是否收到 `AUDIO_START (0x04)`和音频帧；
5. 无论成功或失败，发送 `MIC_CLOSE = 0x0D + sessionID`；
6. 若短时成功，第二轮最多测试 20 秒，并在第 10 秒发送一次 `MIC_EXTEND = 0x0E + sessionID`；
7. 检查实验后按键语音、休眠、重连和充电是否正常。

安全边界：不循环轰炸命令、不先做长时间测试、必须有 5 秒自动停止和手动停止、异常时立即断开并恢复正常按键验证。

## TODO 判定标准

- 收到 `AUDIO_START` 且有连续有效音频帧：判定“无按键短时开麦可行”；
- `MIC_EXTEND` 后跨过原硬件超时仍持续传输：判定“协议级长时间会话可行”；
- 只有按键后才接受 `MIC_OPEN`，或无按键始终返回 `RemoteNotActive` / 无响应：判定 RC003 不支持；
- 可以持续但续航、休眠或隐私指示不可接受：技术上可行，但不进入正式产品路线。

在完成上述实验前，TODO 应保持未完成，结论写为：**正常按键路径必须长按；无按键主动开麦在协议层面可行，RC003 真机尚待验证。**
