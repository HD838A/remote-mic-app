# 连接页出现未在规范中要求的独立 Chromecast 卡片

- 时间：2026-11-20
- 状态：候选修复
- 影响范围：设置 → 连接页右列
- 用户反馈：截图绿框中的独立 Chromecast 卡片不应存在；连接页已有左侧当前设备面板和“连接过的设备”

## 来源

- 引入提交：`32227790f00371f040ee2e9e752d2a4055b07137`
- PR：`HD838A/remote-mic-app#1118`，标题“fix(settings): 恢复连接态 Chromecast 遥控器卡片”，2026-11-18 合入
- 该 PR 的说明只称“恢复卡片”，没有引用新的产品规范或设计稿；合入时 PR 仍标记为 Draft，真实运行截图待补
- 被覆盖的旧代码注释明确写着：“Chromecast 连接卡片已按产品要求移除”
- `Testing/ChromecastHardwareInterface.md` 写明：连接页只在**左列设备面板**显示当前遥控器、照片、三行状态和“重新连接”；侧边栏没有单独的 Chromecast 面板
- `feature/remote-connection-lifecycle/PRODUCT_SPEC.md` 只要求连接页当前设备和“连接过的设备”使用统一卡片，没有要求额外的右侧 Chromecast 卡片

## 处理

- 删除 `SettingsView.chromecastConnectionCard`
- 删除连接页右列的独立渲染分支
- 删除仅供该卡片使用的 `BridgeAppModel.isChromecastHIDPresent`
- 新增回归：设置页不得重新出现 `chromecastConnectionCard` 或 `isChromecastHIDPresent`

Chromecast 的连接状态、重连、语音和按键链路不受影响；左侧设备面板、“连接过的设备”和按键页选择器继续按现有规范工作。

## 边界

- 不删除 Chromecast 在左侧设备面板中的照片、三行状态或“重新连接”入口。
- 不改变 Chromecast 私有包、卡片状态或语音链路。
- 真实 Chromecast 连接态截图由现场设备复验；本次只按用户确认的产品要求移除多出的卡片。
