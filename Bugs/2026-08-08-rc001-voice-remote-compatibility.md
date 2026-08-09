# RC001-MS 语音遥控器适配

- 时间：2026-08-08
- 状态：兼容性调查已归档
- 影响范围：RC001-MS 与 RC003-MS；BLE ATVV、HID 和音频
- 功能点：小米遥控器 2 兼容性
- 简单描述：早期无法确认 RC001 的语音协议与现有 RC003 是否兼容，需通过双设备真机和协议事件验证消除误判。
- 原始记录：DEBUG.md，首次记录 0da5b7e

## 详细过程

## Observations

- 目标设备明确为 Xiaomi Bluetooth Remote Control 2（RC001-MS），不是 RC003-MS Pro，也不是无法连接 Mac 的第三方兼容版。
- RC001-MS 已能与当前 Mac 配对并保持连接；除语音键外的普通按键可被 macOS 或现有 App 识别。
- 当前 `RC003NameMatcher` 明确拒绝 `Xiaomi Bluetooth Remote 2`，因此 RC001 不会按名称进入现有 CoreBluetooth 语音链路。
- 当前蓝牙桥接只发现 RC003 已知的 ATVV Service，并只订阅固定的 control/audio Characteristic；无法观测未知 RC001 Voice Service。
- 当前自定义 HID 监听固定匹配 RC003 的 VID `0x2717` / PID `0x32B8`；MIC 没有普通 keyCode 不能据此判定 RC001 没有语音能力。
- 当前没有 RC001 的 Service UUID、Characteristic UUID、控制包、音频包或 codec 真机证据，不能直接复制或发明 profile。

## Hypotheses

### H1: RC001 与 RC003 使用相同 ATVV UUID、包格式和 codec，只是被设备名称白名单拒绝（ROOT HYPOTHESIS）

- Supports: 两者属于同系列语音遥控器；RC001 的普通 HID 链路已成立；现有扫描本来就会接受广播相同 ATVV Service 的设备。
- Conflicts: 型号不同，尚无 RC001 GATT dump；设备也可能不在广播中暴露 Voice Service UUID。
- Test: 只给精确名称白名单增加 `Xiaomi Bluetooth Remote 2`，保持全部 RC003 协议常量不变，观察是否能完成能力协商并收到 MIC 的 `STREAM_START / AUDIO / STREAM_STOP`。

### H2: RC001 使用相同 ATVV 协议和 codec，但 Voice Service 或 Characteristic UUID 不同

- Supports: 同系列设备可能复用控制包和 IMA-ADPCM，仅更换 GATT profile。
- Conflicts: 没有 RC001 Service Discovery 数据。
- Test: 若 H1 失败，完整发现 RC001 的所有 Service/Characteristic，订阅 notify/indicate，并与 RC003 UUID 和包前缀做 diff。

### H3: RC001 的语音数据通过 HID over GATT 或 vendor-specific HID Report 传输

- Supports: MIC 没有普通 Keyboard/Consumer keyCode；语音遥控器可以通过 HID Report 承载控制和音频。
- Conflicts: 同系列 RC003 已使用自定义 ATVV GATT，RC001 采用完全不同 transport 的成本更高。
- Test: 导出 RC001 HID Report Map，并在 MIC down、讲话、MIC up 三阶段记录 report ID、长度和频率。

### H4: RC001 暴露相近 Voice GATT，但需要不同的初始化写入或通知顺序才开始传输

- Supports: 部分语音遥控器需要先协商能力或由主机写控制特征；普通 HID 可用不代表 Voice Session 已初始化。
- Conflicts: 当前还不知道 RC001 是否暴露任何相近 Voice Service。
- Test: 先比较完整特征属性和 MIC 操作时的被动通知，再对已证实的可写控制特征做单变量初始化实验。

## Experiments

### E1: 仅放行 RC001 精确蓝牙名称

- Change: 在现有 RC003 精确名称集合中临时加入 `xiaomi bluetooth remote 2`，不修改 Service UUID、Characteristic UUID、协议命令或解码器。
- Confirms H1: App 完成 `ATVV CAPS`，按住 MIC 出现 `STREAM START`、连续 `AUDIO`，松开出现 `STREAM STOP`。
- Rejects H1: RC001 被发现后提示 Voice Service 缺失、能力协商失败，或 MIC 全程没有控制/音频数据。
- Result: inconclusive。开发 App 通过 `saved_identifier` 连接到名称为“小米蓝牙语音遥控器”的既有设备，没有经过新增的英文名称分支；该设备完成 RC003 ATVV v1.0 / codec 2 / 120-byte frame 能力协商，但仅凭共用显示名称无法证明它是 RC001。
- Cleanup: 已撤销临时英文名称白名单；没有把实验性设备识别留在正式代码。
- System identity check: 当前唯一连接的“小米蓝牙语音遥控器”由 macOS 报告为 VID `0x2717` / PID `0x32B8`，与现有 RC003 专用 HID 匹配值一致；未连接设备列表中没有 RC001。因此已有 ATVV 成功日志只能作为 RC003 基准，不能用于确认 RC001。

### E2: RC001 全 Service 发现诊断包

- Change: 临时接受精确英文名 `xiaomi bluetooth remote 2`，把连接后的 Service Discovery 从固定 ATVV UUID 改为全部服务，并仅记录 Service UUID 列表；总实验改动不超过 5 行。
- Confirms H1: RC001 服务列表包含现有 `AB5E0001-...` ATVV Service，随后恢复固定发现即可继续验证同协议能力协商。
- Rejects H1: RC001 成功连接但服务列表不包含现有 ATVV Service；下一实验转为逐服务发现 Characteristic。
- Preconditions: RC003 断电或移出连接范围，RC001 已在 macOS 蓝牙设置中连接并保持唤醒。
- Build status: 临时诊断包已通过 production 构建并正在运行；源码中的 3 行实验探针已撤销，因此工作区未残留 RC001 猜测性实现。当前包先连接到仍在线的 RC003，并成功记录其基准 Service：`180F, 180A, AB5E0001-..., 8A7A0001-..., 01BF, FE59`。
- Pending evidence: 需要 RC003 离线并让 RC001 出现在当前 Mac 上，才能记录 RC001 Service 列表并完成本实验结论。

### E3: RC001 / RC003 同时连接时定向选择第二只遥控器

- Observation: RC003 为充电设备，无法直接断电；在 macOS 主动断开后会自动重连。RC001 与 RC003 可以同时连接同一台 Mac。
- Change: 临时诊断包跳过已保存的 RC003 Peripheral Identifier，并在已连接设备和扫描结果中排除该标识，只连接另一只符合精确名称或 ATVV 服务特征的遥控器；继续完整发现 Service 并记录 UUID。实验代码保持 5 行。
- Expected: RC003 保持在线但不会被诊断桥接选中；RC001 连接后成为唯一可选的非缓存候选。
- Identity gate: 收到 RC001 数据前，先使用 macOS 系统报告核对第二只设备的名称、VID/PID 与连接状态，不把共用名称作为唯一身份依据。
- Build status: 双设备诊断包已完成 production 构建并运行，5 行探针随后已从源码撤销。RC001 尚未连接时，诊断包仍找到一个具备相同 ATVV 服务的已连接外围设备；在系统出现第二只设备前，该结果继续按 RC003 处理，不用于 RC001 结论。
- Next action: RC001 连接后先读取两只设备的系统身份，再重启诊断包并根据真实名称、VID/PID 和非 RC003 候选收集数据。

## Root Cause

RC001-MS 与 RC003-MS 使用相同的 macOS HID 身份和 ATVV v1.0 语音协议，但正式代码与测试把名称识别器限定并命名为 RC003，且明确拒绝 RC001 的英文产品名；协议层本身不需要修改。

## Fix

- 将 RC003 专用名称匹配器泛化为小米语音遥控器匹配器，精确接受 `Xiaomi Bluetooth Remote 2` 与现有 RC003 名称，不增加模糊匹配。
- RC001 与 RC003 继续共享现有 ATVV Service、能力协商、16kHz IMA-ADPCM 解码和 PCM 输出，不新增 transport/profile/decoder。
- 更新中英文设备标题、README、单元测试和 Self Test，公开说明支持 2 / 2 Pro。
- 保持当前单语音源行为；两只同时连接时只选择其中一只，不在本次适配中增加多设备切换 UI。
