# RC001 / RC003 型号与充电状态识别

- 时间：2026-08-08
- 状态：已修复
- 影响范围：RC001 与 RC003；设备卡片信息
- 功能点：型号、电量、外部电源与充电状态
- 简单描述：Bug 索引状态：已实现并归档
- 原始记录：DEBUG.md，首次记录 0da5b7e

## 详细过程

## Observations

- 两只真机均报告相同名称、制造商 `MIOM`、VID/PID `0x2717 / 0x32B8`、固件 `2671`、HID Version `164`、ATVV v1.0 能力和完全相同的 HID Report Descriptor。
- IORegistry 能读取两只不同的序列号和物理设备唯一标识；这些值可以稳定区分实体设备，但当前单样本无法证明其中包含型号编码。系统 `Product` 字段为空。
- 两只设备都暴露 Battery Service `180F` 和 Device Information Service `180A`。当前 App 只请求 Battery Level `2A19`，分别读取到 `42%` 与 `100%`。
- `system_profiler` 与 IORegistry 没有为这两只遥控器显示充电中、电源类型或 Battery Status Flags；不能仅凭 `100%` 判断 RC003 正在充电或属于充电型号。

## Hypotheses

### H1: Device Information Service 包含不同 Model Number / Hardware Revision

- Supports: 两只设备存在不同序列号，且都暴露标准 `180A`。
- Conflicts: macOS 缓存中的 `Product` 为空，制造商、固件和 HID 版本完全一致。
- Test: 只读发现 `180A` 全部 Characteristic，并读取 `2A24 / 2A27 / 2A50`。

### H2: Battery Service 暴露标准充电状态（ROOT HYPOTHESIS）

- Supports: 两只设备均暴露标准 `180F`；Bluetooth BAS 可选 `2A1A` 或新版 `2BED` 表示电源/充电状态。
- Conflicts: macOS 当前只呈现电量百分比，没有充电标志。
- Test: 临时发现 `180F` 的全部 Characteristic；存在 `2A1A / 2BED` 时再只读其值，并对 RC003 插拔充电线。

### H3: 广播 Manufacturer Data 或 vendor Service 隐含型号/电源状态

- Supports: 两只设备还有厂商 Service，理论上可能包含内部 SKU 或电源状态。
- Conflicts: 已确认的 Service、协议和 HID 身份完全一致，且未发现公开字段定义。
- Test: 在两只设备重新广播时对比脱敏后的 Manufacturer Data、Service Data 和只读 Characteristic UUID/长度，不猜测未知位含义。

## Experiments

### E4: Battery Service 全 Characteristic 发现

- Change: 临时把 `180F` 的 Characteristic 发现从仅 `2A19` 改为全部，并记录 UUID 列表；不写设备、不改变 ATVV 流程，实验后撤销。
- Confirms H2: 任一设备出现 `2A1A` 或 `2BED`。
- Rejects H2: 两只设备的 `180F` 都只有 `2A19`。
- Result: confirmed。一只设备只有 `2A19`；另一只设备暴露 `2A19, 2BED`，其中 `2BED` 当前值为 `00 61 00`。按 Bluetooth SIG BAS v1.1 解码：电池存在、未连接有线/无线外部电源、充电状态为 `Discharging: Inactive`、充电类型为 Unknown/Not Charging。
- Interpretation: 后续 `2A24` 直接确认暴露 `2BED` 的设备是 RC003；RC001 的 Battery Service 只有 `2A19`。`2BED` 可以作为 RC003 的附加能力，但型号识别应优先使用明确的 Model Number，不依赖电池特征猜测。

### E5: Device Information Service 型号字段

- Change: 临时发现 `180A` 全部可读 Characteristic，记录 UUID 和文本/十六进制值；不写设备，实验后撤销。
- Confirms H1: 两只设备的 `2A24` Model Number、`2A27` Hardware Revision 或 `2A50` PnP ID 存在稳定型号差异。
- Rejects H1: 型号/硬件/PnP 字段缺失、为空或两只完全相同。
- Result: confirmed。两只设备的 `2A24` 分别明确返回 ASCII `RC001` 与 `RC003`；`2A27` 均为 `V2.0`，`2A50` PnP ID 均相同。Model Number 是当前最可靠且语义明确的自动型号来源。
- Cleanup: 已撤销全部 Service/Characteristic 探针，生产代码恢复为只发现 ATVV 与 Battery Level；临时日志未记录蓝牙地址或原始设备唯一标识。

## Conclusion

- 自动型号识别可行：连接后读取标准 Device Information Service `180A` 的 Model Number `2A24`，严格接受 `RC001` / `RC003`；正式界面直接显示识别结果，不再让用户手动选择型号或输入名称，未知值只显示通用遥控器名称。
- RC003 充电状态读取可行：读取 Battery Level Status `2BED`，解析电池存在、外部电源、充电/放电状态、充电等级、充电类型和故障位；RC001 不暴露该特征，只显示电量。
- 当前 RC003 的 `2BED = 00 61 00` 表示未连接外部电源且未处于主动充电。仍需一次插入/拔出充电线验证“正在充电/已接电源”是否实时准确更新，以及该 Characteristic 是否支持 notify。
- 生产代码现已把 `180A / 2A24` 与 `180F / 2BED` 作为不影响 ATVV 初始化的可选读取能力；设备卡可显示自动型号、电量与当前电源状态。插拔充电线的实时变化仍属于待完成真机验收，不能仅凭构建或单元测试声明通过。
