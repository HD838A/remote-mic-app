# RC003 多 Mac 直连切换可行性研究

- 研究日期：2026-07-31
- 研究时仓库基线：Remote Mic 1.4.11 (35)，提交 6736e62e14485ee79a752c343319682052fb6b3b
- 研究对象：同一只小米蓝牙遥控器 2 Pro / RC003-MS 与两台或更多 Mac

本文只研究“遥控器直接连接当前选中的 Mac”。不使用局域网、公网、云端中继或 Mac 间消息转发，也没有修改应用代码。由于本轮没有使用同一只 RC003 和两台真实 Mac 完成配对切换实验，所有依赖遥控器固件和 macOS 系统蓝牙行为的结论都保持为待真机验证。

## 需求定义

目标体验是：

1. 同一只 RC003 先后与 Mac A、Mac B 配对；
2. 两台 Mac 都安装无线麦；
3. 用户在 App 中决定遥控器当前连接哪一台 Mac；
4. 按键、HID 和 ATVV 语音都只进入当前 Mac；
5. 切换过程中不使用任何网络通信。

这里需要区分两个不同目标：

| 目标 | 当前判断 |
| --- | --- |
| 在当前已连接 Mac 上点击“释放”，再到目标 Mac 点击“连接本机” | 有条件可行，必须先通过 RC003 多配对和 macOS 重连真机实验 |
| 只在目标 Mac 上点击一次，就强制另一台 Mac 释放遥控器并切换过来 | 纯本地 App 方案不能保证；目标 Mac 没有 API 可以命令另一台 Mac 断开 |

## 结论摘要

1. **目前仍不能确认 RC003 支持保存两台 Mac。** 小米产品页、Bluetooth SIG 产品记录和 Bluetooth Core Specification 都没有给出 RC003 的 bond 表容量、替换策略或主机切换流程。
2. **Bluetooth 5.4 不等于支持多个配对主机。** Bluetooth SIG 规范只要求参与一次 bonding 的两台设备交换并保存该次 bonding information，没有要求每个外设必须保存两个或更多 peer。
3. **RC003 确实有 Bluetooth SIG 官方产品记录。** Listing 293975 由 Xiaomi Inc. 提交，包含型号 RC003-MS、Design Q360769、Declaration R071731；该 Listing 元数据的规范版本是 5.1，而小米产品页标注蓝牙 5.4。无论采用哪个版本号，都只能说明相应的蓝牙实现或产品规格，不能证明支持多主机或 App 主机切换。
4. **macOS App 只能管理本机的 CoreBluetooth 连接。** Apple 明确说明，取消本地连接不保证底层物理链路立即断开，因为其他 App 仍可能保持连接。RC003 的系统 HID 客户端因此是必须真机验证的关键风险。
5. **macOS 系统设置提供“断开”和“忽略”两个不同操作。** Apple 说明“断开”后设备可能自动重连；只有“忽略”才要求以后重新配对。这意味着可以先验证手动交接，但不能据此推断无线麦 App 能完成同等级别的系统断开。
6. **无网络方案若成立，只能先承诺显式交接。** 当前 Mac 主动释放，目标 Mac 再连接；不能承诺用户只在 Mac B 点击一下，就能强制 Mac A 释放遥控器。
7. **TODO 保持未完成。** 两台 Mac 真机实验通过前，功能既不能标为可实现，也不能武断标为硬件不支持。

## 已确认的证据

### 小米产品资料

[小米蓝牙遥控器 2 Pro 官方页面](https://www.mi.com/xiaomi-bluetooth-remote-2-pro)列出了：

- 产品型号 RC003-MS；
- 蓝牙 5.4；
- 快速配对；
- 小米和 REDMI 电视/盒子兼容；
- NFC、语音和自定义按键。

页面没有说明：

- 能同时保存两台或更多主机的配对密钥；
- 有主机 1 / 主机 2 配对槽位；
- 能通过按键或 GATT 命令切换主机；
- 第二次进入配对模式后是否保留第一次配对。

产品页还写明包装内包含纸质说明书，但截至研究日期，在小米公开产品页和全球 User Guide 入口中没有找到 RC003-MS 的可下载说明书。因此目前只能表述为“小米官方没有公开声明多主机能力”，不能把资料缺失写成“不支持”的直接证据。

### Bluetooth SIG 产品记录

[Bluetooth SIG Qualified Product Listing 293975](https://qualification.bluetooth.com/ListingDetails/293975)、[Listing metadata JSON](https://qualificationapi.bluetooth.com/api/Platform/Listings/Details/293975)和[产品公开日期 JSON](https://qualificationapi.bluetooth.com/api/Platform/ListingDetails/Products/293975)包含：

- Member Company：Xiaomi Inc.；
- Product：Bluetooth Voice Remote；
- Model：RC003-MS；
- Design：Q360769；
- Declaration：R071731；
- Listing metadata 中的 Specification Version：5.1；
- RC003-MS 产品公开日期：2025-08-15。

该 Listing 还包含多个小米语音遥控器型号，共用或引用相关设计。公开产品详情没有列出：

- bond 表容量；
- 多 central 同时连接能力；
- 主机切换按键或 GATT 命令；
- 第二次配对是否覆盖旧 bond；
- 是否实现 Bond Management Service。

Bluetooth Qualification 证明产品按申报设计完成了规范符合性流程，不等于认证了厂商没有申报的产品体验。不能根据该记录推断 RC003 支持或不支持多 Mac。

小米产品页的“蓝牙 5.4”和该 Listing 的 Specification Version 5.1 看起来不同，但公开材料没有解释二者对应的具体层级或组件。研究中不尝试用其中一个覆盖另一个，也不把版本差异当作多配对能力的正面或负面证据。

### Bluetooth SIG 对 bonding 的定义

[Bluetooth Core Specification 5.4，GAP 6.5 Bonding](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host/generic-access-profile.html#UUID-cbed7f95-34a4-2850-32f0-d6f4d9e56187)把 bonding 定义为：两台 Bluetooth 设备基于共同 link key 建立关系，link key 在 bonding 过程中创建、交换，并预期由双方保存以供以后认证。

[GAP 9.4.4 Bonding procedure](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host/generic-access-profile.html#UUID-1ed7b254-f877-2bc6-c824-c749de8dc7cd)进一步要求，进行 bonding 的 peer 应交换 bonding information 并存入 security database。

这两处规范确认“一次 bonding 的信息应保存”，但没有规定一个消费级遥控器必须保存多少个 peer。存储一台、两台或更多主机，以及新配对时删除哪个旧 bond，仍是产品实现问题。

Bluetooth SIG 另有独立的 [Bond Management Service 1.0.1](https://www.bluetooth.com/specifications/specs/bond-management-service-1-0-1/)，定义删除当前设备 bond、删除全部 bonds、删除除当前设备外所有 bonds等操作。这说明标准允许设备维护多个 bonds，也提供了可选的管理方式；但只有设备实际实现该服务时才可使用，不能因为 RC003 标注 Bluetooth 5.4 就假设它具备该服务。

### CoreBluetooth 只能操作本机连接

Apple 官方 API 的边界很明确：

- [CBCentralManager.connect](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect(_:options:))：建立到外设的本地连接；
- [CBCentralManager.cancelPeripheralConnection](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:))：取消本机正在进行或已经建立的连接；
- [scanForPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:))：只能发现正在广播的外设；
- [retrievePeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveperipherals(withidentifiers:))：只能按本机已知标识取回外设对象；
- [retrieveConnectedPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:))：结果可能包含由系统或其他 App 连接的外设，当前 App 仍需另行建立自己的本地连接。

Apple 在 cancelPeripheralConnection 的 Discussion 中明确说明：该调用是非阻塞的；由于其他 App 可能仍连接外设，取消本地连接不保证底层物理链路立即断开。从调用 App 的视角，外设会被视为已断开。

由此可以确认：

- Mac B 可以等待或尝试连接 RC003；
- Mac B 不能调用 CoreBluetooth 去取消 Mac A 的连接；
- 如果 RC003 连接 Mac A 后停止广播，Mac B 扫描不到它；
- Mac A 的 App 取消本地连接，不保证系统中没有其他蓝牙客户端继续持有连接。

本轮还核对了 Xcode 26.4 macOS SDK 的公开 CoreBluetooth headers。CBCentralManager 提供扫描、取回、连接和取消本地连接等接口，没有显式的 pair、unpair、踢掉其他 central 或强制系统 HID 释放外设的公开方法。IOBluetooth 虽有面向 baseband 连接的 closeConnection，但它不是 Apple 为 CoreBluetooth LE/HOGP 系统连接给出的等价控制接口，不能据此设计 RC003 切换方案。

### macOS 用户级“断开”与“忽略”

[Apple《Connect a Bluetooth device with your Mac》](https://support.apple.com/guide/mac-help/connect-a-wireless-accessory-blth1004/mac)说明：

- 用户可以在系统设置的 Bluetooth 列表中点击 Disconnect；
- 如果不希望设备自动重连，需要选择 Forget；
- Forget 之后，以后使用时必须重新连接和配对。

因此，真机实验必须分别测试两条路径：

1. 系统设置点击“断开”后，另一台 Mac 能否接手；
2. 无线麦只取消本地 CoreBluetooth 连接后，另一台 Mac 能否接手。

若第 1 条成功而第 2 条失败，说明 RC003 的多 bond 可能成立，但 App 缺少可靠释放系统 HID 连接的公开接口；这时不能直接进入产品实现。

### 当前应用已经有“本机释放”的底层动作

当前 [XiaomiBluetoothBridge.swift](../../Sources/RemoteMic/XiaomiBluetoothBridge.swift)的 stop 方法会停止扫描，并对本机当前外设调用 cancelPeripheralConnection。start 方法会优先取回本机保存的 peripheralIdentifier，再检查系统已连接外设，最后扫描 RC003。

当前 [AppSettings.swift](../../Sources/RemoteMic/AppSettings.swift)只保存本机看到的一个 peripheralIdentifier。这足以记住“这台 Mac 的 RC003”，但不能表示全局当前目标，也不能告诉另一台 Mac 自己已经释放。

当前实现还会在意外断线后自动重连。若未来真机验证通过，多 Mac 模式必须区分：

- 意外断线：允许当前 Mac 自动重连；
- 用户主动释放：停止自动重连，等待用户再次选择“连接本机”。

否则 Mac A 刚释放，自己的重连逻辑就可能再次抢回遥控器。

## 为什么目标 Mac 不能直接“抢占”

假设 RC003 当前连接 Mac A，用户在 Mac B 点击“连接本机”：

1. 如果 RC003 只允许一个连接，并且连接后停止广播，Mac B 无法发现它；
2. 即使 Mac B 保存过此外设，它发起的连接也只能等待外设可用，不能踢掉 Mac A；
3. Mac B 不知道 Mac A 的 App 是否运行，也无法要求它停止自动重连；
4. 如果 macOS 把 RC003 当作已配对 HID 自动连接，停止无线麦 App 也未必会释放物理链路；
5. 如果 RC003 支持同时连接多个 central，还需要验证 HID 和 ATVV 会发给哪一台，不能假设它们天然只跟随 App 选中的目标。

所以“不使用任何 Mac 间通信”的直接后果是：切换动作必须由当前连接方主动释放，或由遥控器本身提供主机切换能力。现有公开资料没有发现 RC003 的主机切换能力。

## 必须完成的真机实验

实验需要同一只 RC003、Mac A、Mac B，并记录 macOS 版本、遥控器固件或批次、系统蓝牙状态和无线麦日志。

### 实验 1：是否保存两个配对关系

1. 将 RC003 恢复到明确的初始状态；
2. 与 Mac A 配对，确认按键和语音正常；
3. 让 Mac A 完全释放连接，但不要在系统设置中“忽略此设备”；
4. 让 RC003 进入配对模式并与 Mac B 配对；
5. 释放 Mac B 后，尝试让 Mac A 在不重新配对的情况下连接；
6. 再释放 Mac A，尝试让 Mac B 在不重新配对的情况下连接。

只有第 5、6 步都稳定成功，才能证明当前这只 RC003 至少保存了两台 Mac 的配对信息。

### 实验 2：系统设置能否完成手动交接

1. Mac A 连接 RC003；
2. 在 macOS 系统设置的 Bluetooth 列表中对 RC003 点击“断开”，不要选择“忽略此设备”；
3. 在 Mac B 点击连接或扫描 RC003；
4. 记录 RC003 是否重新广播、Mac B 是否无需重新配对即可连接，以及所需时间；
5. 检查 Mac A 是否自动重连并抢回设备；
6. 由 Mac B 断开，再反向验证 Mac A。

若系统设置“断开”也无法交接，则没有必要开发 App 内切换。

### 实验 3：App 释放后是否真正释放物理链路

1. Mac A 连接 RC003；
2. 在无线麦中停止 HID 监控和蓝牙桥接，并调用 cancelPeripheralConnection；
3. 确认无线麦不会自动重连；
4. 在 Mac B 扫描并连接 RC003；
5. 记录 RC003 是否重新广播、出现所需服务以及等待时间；
6. 检查 Mac A 的系统 HID 是否仍保持连接或立即抢回。

若系统设置“断开”可以交接，但无线麦的本地取消不能交接，则问题位于 macOS 系统连接所有权。除非找到 Apple 支持的系统级释放接口，否则 App 内切换仍判定为不成立。

### 实验 4：重复交接稳定性

按以下顺序至少循环 20 次：

Mac A 连接 → A 释放 → Mac B 连接 → B 释放 → Mac A 连接

每次都验证：

- 不需要重新进入配对模式；
- 目标 Mac 在可接受时间内连接；
- 原 Mac 不再收到按键；
- HID 普通按键和 ATVV 语音落在同一台 Mac；
- 没有双端同时响应、卡键或语音会话残留。

### 实验 5：系统生命周期

至少覆盖：

- 两台 Mac 同时开机；
- 当前 Mac 睡眠和唤醒；
- 目标 Mac 睡眠和唤醒；
- 无线麦退出和重启；
- RC003 重启或电量耗尽后恢复；
- 两台 Mac 重启后的首次连接；
- 两台 Mac 距离很近时的连接竞争。

## 通过和失败标准

### 判定可实现

必须同时满足：

- RC003 保存 Mac A、Mac B 的配对关系；
- 两台 Mac 来回切换时不需要重新配对；
- 当前 Mac 的 App 能释放连接，且系统 HID 不会立即抢回；
- 释放后目标 Mac 能发现或连接 RC003；
- 20 次交接无错误目标、双端响应或语音异常；
- App 可以明确区分主动释放和意外断线。

通过后，产品文案应写成“先释放当前 Mac，再连接目标 Mac”，除非额外实验证明目标端单击抢占也稳定可用。

### 判定纯 App 方案不支持

出现任一情况即可判定当前硬件方案不成立：

- 与 Mac B 配对后，Mac A 的配对关系被覆盖；
- 每次切换都必须让 RC003 重新进入配对模式；
- App 取消连接后，macOS HID 仍保持或立即恢复连接；
- RC003 不重新广播，目标 Mac 无法连接；
- HID 与 ATVV 被不同 Mac 接收；
- 两台 Mac 的连接竞争无法稳定控制。

失败时应在 TODO 中明确写为“RC003 硬件/系统蓝牙限制，纯 App 无法实现”，而不是转向网络转发方案。

## 真机验证通过后的最小实现边界

只有实验通过后才进入实现，预计只涉及：

| 组件 | 最小修改 |
| --- | --- |
| XiaomiBluetoothBridge.swift | 增加明确的“连接本机”和“主动释放”状态；主动释放后禁止自动重连 |
| BridgeAppModel.swift | 管理用户选择的本机连接状态，并把主动释放与故障重连分开 |
| SettingsView.swift | 增加“连接到这台 Mac”和“释放遥控器”按钮及当前状态说明 |
| AppSettings.swift | 保存本机是否允许自动连接；继续使用本机 peripheralIdentifier，不建立跨 Mac 设备列表 |
| HIDRemoteMonitor.swift | 仅在本机实际拥有 RC003 时启动，释放时同步停止并清理按键状态 |

不需要新增：

- Bonjour；
- Network.framework；
- 公网服务器；
- 账号、设备授权或 Mac 间配对；
- 按键或语音网络协议；
- 云端存储。

## 最终决策

**保留“同一个遥控器在多台已配对 Mac 之间切换蓝牙连接”TODO，但当前状态为硬件可行性待验证，不能写成已经确认可以实现。**

下一步不是开发，而是按本文使用同一只 RC003 和两台 Mac 做真机实验。通过后实施“当前 Mac 主动释放 → 目标 Mac 主动连接”的最小方案；失败则在 TODO 中明确记录 RC003 或 macOS 蓝牙限制，停止该功能，不引入网络转发。
