# iOS TestFlight 辅助操作被拆成独立设置项

## 复现

- 环境：macOS 27，中文浅色设置窗口；用户提供的“连接”页截图。
- 操作：滚动到“iPhone、Apple Watch 与网页版”，观察 iOS App 及其 TestFlight 操作。
- 实际结果：“打开 TestFlight 公测 / 复制链接”位于独立 `HStack` Form 行，被系统分隔线从 iOS App 标题、说明、状态和“连接手机”中切开，看起来像与 iOS、Apple Watch、网页版并列的第四个设置项。
- 预期结果：两个 TestFlight 操作作为 iOS App 的辅助操作，与该项的标题、说明、状态和主操作属于同一个原生设置行；Apple Watch 前才出现下一条系统分隔线。

## 日志结论

检查同时间段 `SayAll` / `RemoteMic` unified log，没有发现 iPhone、Watch、Web、TestFlight 或页面状态错误。问题可由静态初始状态稳定复现，属于 Form 内容结构错误，不是连接状态机故障。

## 根因

`phoneConnectionsPanel` 先生成 iOS `connectionOptionRow`，随后又把 TestFlight `Link` 和复制 `Button` 作为独立 `HStack` 放进 `Group`。SwiftUI `Form` 会把 `Group` 的每个直接子项识别为同级行并自动插入分隔线，因此辅助操作脱离了其所属设置。

## 修复

- 为 `connectionOptionRow` 增加可选的 `auxiliaryActions` 结构重载。
- iOS App 使用同一个 `VStack` Form 行：主 `LabeledContent` 保持标题、说明、状态和连接按钮的系统标签/尾部控件对齐；TestFlight 与复制按钮放在该行下方的尾部对齐区。
- Apple Watch、网页版和受信任设备继续使用原有独立原生行；连接、取消等待、断开、TestFlight 打开和剪贴板行为未改动。

## 验证

- Xcode 27 下 `swift test --filter SettingsPageRegressionTests`：32 项通过。
- Xcode 27 下 `swift test`：32 个 suite 共 345 项通过。
- `scripts/build-app.sh` 与 `scripts/verify-app.sh dist/SayAll.app` 通过。
- 中文浅色、深色 800pt 最小宽度生产视图展开检查：iOS 标题与“尚未开启 / 连接手机”恢复同一主行，两个辅助按钮右对齐且没有内部系统分隔线；下一条分隔线只位于 Apple Watch 前。

## 验证边界

本机 Computer Use 的 ScreenCaptureKit 桌面流两次返回系统捕获失败，因此没有完成真实鼠标滚动截图；改用同一生产 `SettingsView` 的 800pt 最小宽度展开渲染检查目标模块。真实 iPhone、Apple Watch、网页版会话、TestFlight 跳转、剪贴板、等待 spinner、键盘焦点、VoiceOver 与 macOS 14/15 仍需按测试手册现场验收。
