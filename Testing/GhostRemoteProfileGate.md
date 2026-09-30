# 幽灵遥控器卡片门禁测试手册

## 适用范围

- 目标分支：包含 `Bugs/2026-09-05-ghost-remote-profile-from-unready-peripheral.md` 修复的分支
- 覆盖改动：设备档案只在 BLE 连接达到 `.ready`（ATVV 能力协商通过）后才落盘；`.ready` 之前到达的电量、电源、型号读数先按外设身份暂存，落盘后补回
- 缺陷记录：[`Bugs/2026-09-05-ghost-remote-profile-from-unready-peripheral.md`](../Bugs/2026-09-05-ghost-remote-profile-from-unready-peripheral.md)
- 不覆盖：删除已有设备档案。修复前产生的幽灵卡片仍会显示，本手册不验证其消失

## 测试前准备

1. 记录当前档案数量基线，后续每一步都与它对比。下面命令只在本机查看，不得把设备标识原样贴到 Issue 或日志：

```
defaults export com.hd838a.RemoteMic - | python3 -c '
import plistlib,sys,json
d=plistlib.loads(sys.stdin.buffer.read())
profiles=json.loads(d["remoteDeviceProfiles"])
print("profile_count", len(profiles))
for p in profiles:
    print("model", p["model"], "has_bluetooth", p.get("bluetoothIdentifier") is not None, "has_hid", p.get("hidFingerprint") is not None)
'
```

2. 在设置的诊断区域点击“在 Finder 中显示日志”，记录测试开始后新生成的 `.rmlog` 会话文件名；`.rmlog` 是加密文件，App 和普通用户不能直接读取。
3. 准备一只真实 RC001 或 RC003 遥控器，电量非满（便于确认电量不是默认值）。
4. GRP-03 需要第二个会以 `MI RC` 广播的小米遥控设备。没有的话该用例记为**未执行**，不得记为通过。

## 用例

### GRP-01 全新遥控器首次连接，型号与电量必须正确（核心用例，最大回归风险）

本次改动把型号和电量的写入推迟到握手完成，这是唯一可能弄坏正常功能的地方。

1. 退出 App。
2. 移除全部已有档案，制造"全新用户"状态：`defaults delete com.hd838a.RemoteMic remoteDeviceProfiles` 与 `defaults delete com.hd838a.RemoteMic selectedRemoteProfileID`。
3. 启动 App，等待遥控器连接成功。
4. 打开设置的连接页。

预期：

- 只有一张卡片，且**不是**「小米遥控器」——RC003 应显示「小米蓝牙遥控器 2 Pro」，RC001 应显示「小米蓝牙遥控器 2」。
- 卡片显示绿色「已连接」。
- 电量显示具体百分比，**不是** `—`，且与遥控器实际电量相符。
- 支持侧解密日志中 `BLE MODEL identified=`、`BLE READY`、`REMOTE PROFILE ... result=persisted` 和 `REMOTE PROFILE_TELEMETRY ... result=applied` 依次出现。

失败判定：卡片显示「小米遥控器」；或电量停在 `—` 超过 30 秒；或存储中 `model` 为 `unknown`。任一条命中说明暂存值没有补回，属于本次改动引入的回归。

### GRP-02 断电重连后不新增卡片

1. 在 GRP-01 之后，关闭遥控器电源（或按住配对键使其休眠）30 秒。
2. 重新唤醒，等待重连成功。
3. 重复"测试前准备"第 1 步。

预期：档案数量不变，`bluetoothIdentifier` 不变，卡片仍只有一张，电量恢复显示。

失败判定：档案数量增加；或型号退回 `unknown`。

### GRP-03 附近存在 `MI RC` 设备时不得新增卡片（验证修复本身）

1. 让真实遥控器保持连接。
2. 把第二个以 `MI RC` 广播的小米遥控设备通电放在 Mac 附近，静置 5 分钟，期间不要操作它。
3. 由支持侧确认日志出现 `BLE CONNECTED name=MI RC`（这是本用例的前提，没有出现说明没触发到，记为未执行）。
4. 确认同一尝试没有 `BLE READY name=MI RC`，并出现 `REMOTE PROFILE_TELEMETRY ... result=discarded reason=bridge_not_ready`。
5. 重复"测试前准备"第 1 步，并查看连接页。

预期：档案数量与卡片数量都不变；不出现新的「小米遥控器」卡片。

失败判定：出现新卡片；或存储中新增了一条 `model=unknown` 的档案。

### GRP-04 第二只真实遥控器仍然能被添加

修复不得把"多遥控器"能力一起关掉。

1. 准备第二只真实 RC001/RC003，与第一只不同。
2. 第一只保持连接，让第二只开机进入可连接状态。
3. 等待第二只遥控器进入已连接状态；支持侧日志应出现第二次 `BLE READY`。

预期：连接页出现第二张卡片，且带正确型号与电量；两张卡片可分别点选，各自的按键映射互不影响。

失败判定：第二只真实遥控器握手成功（日志有 `BLE READY`）但卡片不出现。

### GRP-05 幽灵设备在场时，真实遥控器仍能首次配对（已知代价，测时长而非判对错）

修复后失败的外设不再落盘，因此不会从常驻发现桥的候选中"退休"，发现桥可能反复挑中它。代码上不会锁死（失败后会重置外设并重新扫描），但首次配对可能变慢，这一条就是量这个时长。

1. 让会失败的 `MI RC` 设备通电放在附近。
2. 准备一只**从未连过本机**的真实 RC001/RC003，开机进入可连接状态。
3. 记录从开机到真实遥控器显示已连接的耗时；支持侧再核对 `BLE READY` 时间与期间 `BLE CONNECTED name=MI RC` 的次数。

预期：真实遥控器最终连上并出卡片。

失败判定：超过 3 分钟仍未出现 `BLE READY`，或日志显示发现桥一直只连 `MI RC` 从不尝试真实遥控器——那说明"不是锁死"的判断不成立，需要补失败身份退避。

## 稳定功能回归

以下在 GRP-01 完成后各做一次，与上一正式版行为对比：

1. 语音键：按住说话，豆包（或所选语音工具）能正常接收，松开后停止。
2. 普通按键：至少验证两个自定义映射按键（如 `tv`、`menu`）动作正确。
3. 电量与电源：接上电源后卡片出现充电标记。
4. 切换设备卡片后再切回，按键映射与切换前一致。

## 日志收集

在设置的诊断区域打开日志目录，只提交本次测试新生成的 `.rmlog` 会话文件。支持侧解密后检查 `BLE CONNECTED / BATTERY / POWER / MODEL / READY` 与 `REMOTE PROFILE / REMOTE PROFILE_TELEMETRY` 的顺序；不得把设备 UUID、系统设备名或其他身份字段复制到公开 Issue。档案基线只提交数量、型号和“是否绑定”布尔值。

## 验证边界

- 已完成（自动化）：`Tests/RemoteMicTests/RemoteProfilePersistenceTests.swift` 四项，覆盖"未握手不落盘"、"握手后补回暂存读数"、"被放弃尝试的读数不得回放"、"读取失败作废暂存值"。测试通过注入 `targetIdentifier` 构造 bridge，**没有真实 CoreBluetooth**，也没有真实外设的时序抖动；发现桥自行解析外设身份那一段未被覆盖。
- 已完成（自动化）：`swift test --disable-keychain` 758 项、项目自检 48 项、Release 构建、仓库边界检查与 `git diff --check`。
- 待 PR 完成（自动化）：GitHub Apple Silicon / Intel Ventura 双架构 CI。
- 未完成（须用户实测）：GRP-01 至 GRP-05 全部用例，以及上面的稳定功能回归。其中 GRP-01 是判断本次改动是否弄坏正常显示的唯一途径，GRP-05 是量化已知代价的唯一途径，自动化都无法替代。
- 无法由代理执行：全部用例都需要真实蓝牙遥控器硬件；GRP-03 与 GRP-05 还需要第二台以 `MI RC` 广播的设备。
