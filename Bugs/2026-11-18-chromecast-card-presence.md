# Chromecast 已连接且按键响应时卡片仍显示状态确认中

- 时间：2026-11-18
- 状态：候选修复
- 影响范围：Chromecast 遥控器卡片按键就绪状态
- 现场现象：2.0.9 Build 407 中 Chromecast 已连接、普通按键有响应，顶部卡片仍显示橙色“状态确认中”

## 证据

- 截图显示 Chromecast 卡片第三行为“状态确认中”，同一页面普通按键映射正常。
- 卡片按键状态读取 `chromecastHIDIsPresent`：
  - `BridgeAppModel.swift:7838`：`chromecastHIDIsPresent.map { $0 ? .ready : .failed } ?? .unknown`
- 该变量只由 `chromecastFeature.onHIDPresenceChange` 写入：
  - `BridgeAppModel.swift:1317`
- `ChromecastFeatureIntegration` 只声明 `onHIDPresenceChange`，没有调用点：
  - `ChromecastFeatureIntegration.swift:244`
- 私有包实际提供 `isHIDRemotePresent`：
  - `SayAllChromecastFeature.swift:139`：`hidBridge.isDeviceConnected`
  - `SayAllChromecastFeature.swift:83`：HID presence 只写入日志，没有转发为宿主回调

## 根因

Chromecast 按键执行走 `onControlEvent`，该链路完整，所以按键有响应。卡片状态走另一条 HID presence 缓存链路，但缓存回调从未触发，`chromecastHIDIsPresent` 一直是 `nil`。`nil` 被映射为 `.unknown`，最终 `RemoteDeviceCardStatus.resolve` 返回 `.confirming`，界面显示“状态确认中”。

小米和苹果的按键就绪信号都有真实回调更新，所以只有 Chromecast 出现这个矛盾。

## 修复

- `RemoteFunctionReadiness.chromecastButtons(cachedPresent:livePresent:)`：缓存没有值时读取私有包实时 `isHIDRemotePresent`；实时在线直接判定按键就绪。
- HID 缺失没有可靠的“已确认失败”信号时返回 `.unknown`，不伪报红色“按键异常”。
- 链路状态变化和普通按键事件到达时刷新 `chromecastHIDIsPresent` 快照，并发送界面更新与脱敏日志。
- `isChromecastHIDPresent` 同样读取实时快照，设置页 Chromecast 卡片可见性不再依赖失效回调。
- 新增回归：实时 presence 为 true 且缓存为 nil 时必须返回 `.ready`；缓存和实时都缺失时保持 `.unknown`。

## 边界

- 不修改私有包，不假设私有 presence 回调可用。
- 不证明真实 Chromecast 语音、触摸或全部按键；只修复卡片按键就绪状态。
- 私有包完全缺失时仍走原有不可用路径，不新增界面。

## 验证

- 定向 `ChromecastIntegrationTests|SettingsPageRegressionTests|LocalizationTests`：112 tests / 3 suites passed。
- 待执行：公开全量测试、公开构建、仓库治理检查和真机卡片复验。
