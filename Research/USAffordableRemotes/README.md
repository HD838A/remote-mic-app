# 美国低价语音遥控器适配研究

研究日期：2026-08-03

## 目标与结论

目标是在美国能较方便购买、价格低于或接近现有海外硬件方案，并且能较小成本接入“无线麦”的语音遥控器。这里的“容易适配”同时要求：Mac 能直接连接、普通按键可读取、遥控器麦克风能传输真实音频，而不是只看商品标题是否写有 Voice Remote。

当前结论：

1. **Ugoos UR02 是最值得先买的工程样机。** 它不是普通的 2.4GHz USB 空中鼠标，而是官方明确标注的 Bluetooth + 红外遥控器。公开真机记录确认它暴露与 RC003 相同的 ATVV UUID，并能协商到 ATVV v1.0、16kHz ADPCM，和项目现有语音链路最接近。
2. **G20BTS Plus 是价格优化样机，不是最低开发成本样机。** Amazon 美国当前约 19.99 美元且已有 ATVV 实测，但公开研究中的 G20S Pro 主要使用 ATVV v0.4、8kHz，当前 App 会明确拒绝 8kHz，需要增加协议和音频兼容层。
3. **Google Chromecast with Google TV Voice Remote 协议匹配度高，但当前官方缺货。** Google Store 标价 19.99 美元，另一套真机日志已确认 ATVV v1.0、16kHz；适合补货后测试，不适合作为当前唯一推广硬件。
4. 首轮建议购买 **1 个 UR02 + 1 个明确标注 Bluetooth 5.0 的 G20BTS Plus**。先用 UR02验证最小改动，再用 G20BTS Plus 判断为了更低硬件成本支持 8kHz / ATVV v0.4 是否划算。

价格和库存会变化；本文记录的是研究日期当天页面状态，不是长期报价承诺。

## 候选排名

| 排名 | 候选 | 美国当前渠道与价格 | 已知语音协议 | 与现有 App 的距离 | 当前建议 |
| --- | --- | --- | --- | --- | --- |
| 1 | Ugoos UR02 | [Amazon US，ASIN B0D6VFR5R3](https://www.amazon.com/dp/B0D6VFR5R3)，约 22.95 美元；第三方销售、Amazon 配送 | 同一 ATVV UUID；真机日志可协商 v1.0、16kHz，OnRequest，frame size 128 | 语音主链路高度接近；仍需处理设备识别、协商重试、HID 映射和真机音质 | **优先购买并适配** |
| 2 | Google Chromecast with Google TV Voice Remote | [Google Store](https://store.google.com/us/product/chromecast_google_tv_voice_remote?hl=en-US)，19.99 美元，当前 Out of stock | 真机验证 ATVV v1.0、16kHz、frame size 160 | 语音协议很接近；需验证 macOS 配对、HID 和 CoreBluetooth 共存 | 补货后购买 |
| 3 | G20BTS Plus / G20S Pro | [Amazon US，ASIN B0BNH17D18](https://www.amazon.com/dp/B0BNH17D18)，约 19.99 美元，当前有货 | 已验证 ATVV；G20S Pro 公开样机为 v0.4、8kHz、134-byte frame | 当前 App 只接受 16kHz；需增加 8kHz、旧协议帧格式和会话差异 | 作为降成本第二样机 |
| 暂缓 | 未锁定 SKU 的通用 G10S/G20S/2.4G Voice Remote | Amazon、eBay 等价格浮动较大 | 可能是 BLE ATVV，也可能只通过 USB 接收器传输按键或语音 | 同名不同硬件和固件，无法远程确认；批量推广风险高 | 不按商品标题直接承诺兼容 |

## Ugoos UR02 详细判断

### 官方能确认的事实

[Ugoos 官方产品页](https://ugoos.com/ugoos-bt-remote-control-ur02)和[官方说明书](https://ugoos.com/files/uploads/6270845f05e2882d8fb7968d77fb0dfd.pdf)确认：

- 型号为 UR02；
- 同时支持红外和 Bluetooth 4.1、4.2、5.0；
- 内置语音搜索麦克风；
- 24 个按键，其中 10 个支持红外学习；
- 带陀螺仪和空中鼠标模式；
- 使用 2 节 AAA 电池，无遮挡距离最长约 8 米；
- 配对时遥控器名称为 `Ugoos Remote`；恢复出厂设置会清除此前配对。

这意味着 UR02 可以直接与 Mac 的蓝牙栈交互，不依赖 USB 接收器。空中鼠标和红外学习是额外卖点，但第一阶段不应把它们列为语音适配的前置条件。

### ATVV 与 16kHz 证据

[BlueZ issue #1086](https://github.com/bluez/bluez/issues/1086)中的 UR02 真机信息列出了：

- BLE 名称 `UR02`；
- HID over GATT、Battery 和 Device Information 服务；
- ATVV 服务 `AB5E0001-5A21-4F05-BC7D-AF01F617B664`；
- Bluetooth modalias `v0508p1980d0000`。

这与项目 `Sources/RemoteMic/ATVVProtocol.swift` 中当前使用的 ATVV 服务 UUID 完全一致。

同一只公开 UR02 后续在 [ATVVoice issue #18](https://github.com/b0o/ATVVoice/issues/18)中完成了真实协商：

```text
CAPS_RESP: version=v1.0, codecs=ADPCM_8KHZ | ADPCM_16KHZ,
model=OnRequest, frame_size=128
Negotiated protocol: v1.0 (Adpcm16kHz, 16000Hz)
```

因此 UR02 并不是“只知道有麦克风、协议未知”的候选，而是已有第三方真机证据表明它可以走现有项目熟悉的 ATVV v1.0 + 16kHz 路线。

### 为什么仍不能直接宣布兼容

1. **首次能力协商偶发超时。** 上述日志中第一次发送 `GET_CAPS` 后 5 秒没有收到响应，第二次才成功。当前 `XiaomiBluetoothBridge` 每个连接周期只发送一次能力请求，8 秒初始化超时后会断开重连；真机可能能靠重连恢复，但产品体验需要验证是否应增加同连接内的有限重试。
2. **按键模型与 RC003 不一定相同。** UR02 的方向键、语音键、主页键、返回键、彩色键、空中鼠标键都需要采集真实 HID usage；不能复用 RC003 的按键表后直接宣布完成。
3. **语音停止行为存在差异。** [ATVVoice issue #14](https://github.com/b0o/ATVVoice/issues/14)记录过 UR02 开麦后语音键不能按预期停止、仍持续收到音频帧的情况。需要确认无线麦应采用按住、单击切换、超时关闭还是语音活动检测。
4. **存在丢帧记录。** 公开日志中有零星 sequence gap。需要判断是 Linux/BlueZ 环境、距离、设备固件还是遥控器本身造成，并在 macOS 上录制长音频验证可懂度。
5. **固件升级不适合 Mac-only 用户。** Ugoos 官方只提供 Android APK 升级器；[升级说明](https://ugoos.com/files/uploads/780ca34082fbc8de037a89a93837d446.pdf)要求 UR02 先连接 Android TV Box，再由 APK 更新。发布兼容列表前必须记录测试固件，避免不同批次行为不一致。
6. **美国供货仍是第三方渠道。** Amazon 页面当前由第三方卖家销售并由 Amazon 配送，不等于 Ugoos 在美国有长期官方库存。推广前应至少观察一段时间的价格、库存和卖家变化。

## 与当前代码的具体差距

现有实现已经具备：

- `ATVVProtocol.serviceUUID` 与 UR02 相同；
- 扫描结果若广播相同服务 UUID，即使名称不是 RC003 也可以成为候选；
- 主动发送 ATVV v1.0 `GET_CAPS`；
- 能在能力响应中优先选择 16kHz codec；
- 已有 16kHz IMA ADPCM 解码、增益处理和虚拟麦克风输出。

UR02 真机通过前，只考虑以下最小改动，不提前实现：

1. 采集 macOS 蓝牙日志，确认 UR02 是否在广播包中包含 ATVV UUID；若没有，才把精确名称 `UR02` / `Ugoos Remote` 加入候选匹配，不能使用模糊前缀。
2. 在同一连接内对 `GET_CAPS` 增加次数受限的重试，仅在真机确认确有必要后实施。
3. 为 UR02 建立独立 HID usage 表，不改变 RC003 的既有映射。
4. 根据真机行为决定语音键是 hold-to-talk、toggle 还是 OnRequest 超时模型。
5. 空中鼠标和红外学习放到第二阶段；第一阶段只要求方向、确定、返回、主页、菜单、音量和语音可靠。

预计如果 UR02 在 macOS 上能稳定返回 v1.0 / 16kHz 能力，第一阶段工作量为**小到中等**；如果只能返回 v0.4 / 8kHz，工作量会接近 G20S Pro 路线，不能再称为最小适配。

## G20BTS Plus / G20S Pro 的取舍

[ATVVoice README](https://github.com/b0o/ATVVoice)把 G20S Pro、G20S Pro Plus、G20BTS Plus列为已验证设备。其[协议研究](https://github.com/b0o/ATVVoice/blob/main/docs/research/report.md)记录的具体 G20S Pro 样机为：

- 同一个 ATVV 服务 UUID；
- ATVV v0.4；
- IMA/DVI ADPCM 8kHz；
- 134-byte frame；
- BLE VID `1d5a`、PID `c081`；
- 语音键没有可靠的长按/松开状态，主机要自行管理会话。

当前项目的 `ATVVProtocol.supportsAudio` 只允许 16kHz，因此这条路线至少需要：

- 支持 8kHz 输出或安全上采样到现有 16kHz 虚拟声卡；
- 覆盖 v0.4 的能力协商、`MIC_OPEN` / `MIC_CLOSE` 负载差异；
- 正确处理 134-byte 帧内 DVI predictor / step index；
- 为缺少 release 事件的语音键定义清晰停止规则；
- 锁定确切商品、VID/PID、蓝牙名称和固件，避免买到只有 2.4GHz USB 的同名版本。

它的硬件价格略低，但工程成本和批次风险明显高于 UR02。因此适合作为第二台“能否进一步降价”的样机，而不是第一台。

## Google Voice Remote 的取舍

[Google Store 官方页面](https://store.google.com/us/product/chromecast_google_tv_voice_remote?hl=en-US)当前标价 19.99 美元，确认内置 Google Assistant 麦克风，但研究日期当天显示 `Out of stock — get notified`。

[BlueZ issue #1086 的后续真机报告](https://github.com/bluez/bluez/issues/1086#issuecomment-5089723424)使用 Chromecast with Google TV Voice Remote 成功得到：

```text
CAPS_RESP: version=v1.0, codecs=ADPCM_16KHZ,
model=HoldToTalk, frame_size=160
```

协议匹配度很高，但要注意：

- 该报告来自 Linux/BlueZ，不等于 macOS 已验证；
- 配对可能要求能确认 Numeric Comparison 的 agent，遥控器本身没有屏幕；macOS 如何呈现和处理需真机验证；
- 官方当前缺货，不能作为唯一推广链接；
- Google 已从 Chromecast 转向 Google TV Streamer，旧遥控器的长期供货需要持续观察。

## 首批真机验收清单

每个候选至少记录以下结果后，才能进入公开兼容列表：

1. 美国实际到手商品链接、卖家、包装型号、FCC ID、VID/PID、固件版本和蓝牙名称；
2. macOS 14、15 和当前开发系统上的首次配对、重连、睡眠唤醒；
3. CoreBluetooth 能发现 ATVV 服务，同时系统 HID 按键仍然可用；
4. `GET_CAPS` 响应版本、codec、interaction model、frame size 和首次成功耗时；
5. 所有按键的 down/up HID usage，不把空中鼠标数据误当普通按键；
6. 连续完成 100 次语音会话，确认开始、停止、超时和断连恢复；
7. 每次录音至少 30 秒，检查丢帧、点击声、音量和语音识别准确率；
8. 电池低电量、8 米距离、休眠后首次按键和多次 App 重启；
9. 若同一商品补购第二只，确认硬件与协议没有因批次变化；
10. README 只引用已真机验证的精确 SKU，不使用“所有 G20S/UR02 兼容”之类泛化承诺。

## 最终建议

**UR02 值得买，而且应排在当前美国低价候选的第一位，但它是“最可能低成本适配”的工程结论，不是已经兼容。**

如果只买一只，先买 UR02；如果能买两只，再加 Amazon 上明确标注 Bluetooth 5.0 的 G20BTS Plus。UR02 用来快速验证现有 16kHz ATVV 链路能否复用，G20BTS Plus 用来评估为了约 3 美元的硬件价差承担 8kHz / v0.4 开发和同名批次风险是否划算。Google Voice Remote 等官方补货后再加入第二轮。
