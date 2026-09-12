# Siri Remote 页面布局与 AppSwitcher 回归

## 复现

- 设备：Apple Siri Remote A2854；对照设备：RC003。
- 页面：连接页、按键映射页。
- 操作：在两个设备之间切换；在 A2854 上将 TV 配置为 `Command-Tab`，随后按左右键。
- 错误行为：连接页两种遥控器视觉尺寸不一致；Siri 页面顶部留白明显大于 RC003；切换到 RC003 后保留旧页面下半段滚动位置；TV 的 Cmd-Tab 不稳定，左右键会落入普通方向动作并直接选中 App。

## 日志与证据边界

当前工作树没有这次用户现场的 `runtime.log` 事件链，只有早期无 PacketLogger 探针日志。因此本次根因结论来自可重复的静态代码路径和自动化测试，不宣称已经完成 A2854 真机验收。

## 根因

1. 连接页 `connectionDevicePanel` 固定渲染 `RC003Photo`，没有按选中 profile 型号切换图片。
2. Siri 页面卡片首行中心为 118.65 pt，而 RC003 首行约为 45.6 pt；两个独立滚动容器也没有用设备 profile identity 重建。
3. Siri Remote 的 `.appSwitcher` 走通用单次 `KeyboardInjector.send`，没有复用 RC003 的 `AppSwitcherSession`，因此 Command 没有跨事件保持，左右键继续走普通动作路由。

## 修复

- 私有 `SayAllSiriRemote` 增加 A2854 连接页缩略图组件；宿主连接页按 profile 型号选择并保持统一 82×166 pt 外框。
- A2854 映射页将首行对齐到 RC003 节奏，保持卡片不重叠；两个映射滚动容器使用 `selectedRemoteProfileID` identity，切换设备时回到顶部。
- 宿主为 Apple Remote 增加 `KeyboardInjector.AppSwitcherSession` 生命周期：TV 首次启动/继续 Tab，左右发送 Cmd+左右，中心确认，返回取消，超时和设备状态清理释放 Command；所有阶段写入脱敏日志。

## 自动化验证

- 私有包 `SiriRemoteMappingPageTests`：覆盖首行节奏、列平衡、间距和不重叠。
- 公开宿主默认构建：覆盖社区版独立构建及稳定功能回归。
- 公开宿主启用 Siri Remote UI-only 依赖：覆盖宿主路由、缩略图链接、滚动复位和 AppSwitcher 生命周期接线。

## 真机验收边界

仍需在真实 A2854 上确认：连接页实际视觉比例、切换页面滚动位置、TV/左右/中心/返回的系统 AppSwitcher 行为，以及超时/断连后 Command 是否确实释放。自动化和构建通过不能替代这些实机步骤。
