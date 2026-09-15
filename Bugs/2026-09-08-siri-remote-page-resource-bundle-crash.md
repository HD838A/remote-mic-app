# 2026-09-08 点击 Siri Remote 页面因资源 Bundle 路径崩溃

- 时间：2026-09-08
- 状态：源码修复完成，等待新测试包页面点击复验
- 影响范围：无线麦SayAll.app 1.9.21 (174)，启用私有 Siri Remote Package 的 macOS 安装包
- 功能点：Siri Remote 连接/按键页面图片资源加载

## 复现

用户在当前 Mac 安装并运行 1.9.21 (174)，点击 Siri Remote 入口后 App 发生一次崩溃。崩溃报告为
`EXC_BREAKPOINT / SIGTRAP`，主线程在 SwiftUI `GeometryReader`/`DynamicViewList` 布局期间触发 Swift `fatalError`。

## 日志与证据

- 崩溃报告：`/Users/andy/Library/Logs/DiagnosticReports/RemoteMic-2026-09-08-222411.ips`。
- 同时段运行日志显示 A2854 已连接，触摸已附着，`MiRemoteV 2ch` 已 ready；因此不是蓝牙连接或音频初始化导致的崩溃。
- `packet_stream_authorization_rule_too_weak` 是 HCI 授权失败的独立已知状态，未出现在 SwiftUI 崩溃调用链中。
- 私有包的 `SiriRemoteDeviceCapabilities`、`SiriRemoteConnectionPhoto` 和 `SiriRemoteMappingPage` 直接访问 `Bundle.module`。SwiftPM 访问器会把 `.app` 根目录和构建机绝对路径作为候选；发布脚本实际将资源放到 `.app/Contents/Resources/SayAllSiriRemote_SayAllSiriRemote.bundle`。

## 根因确认

安装后的用户机器没有发布机的 SwiftPM 构建缓存，三个页面入口无法解析资源 Bundle，SwiftPM 生成的访问器调用 `fatalError`，最终表现为 SwiftUI 页面构建期间的 SIGTRAP。开发机保留构建缓存时会掩盖该问题。

## 修复

- 私有包新增 `SayAllSiriRemoteResources`，优先从 `Bundle.main.resourceURL` 解析标准 App 资源 Bundle，非 App/SwiftPM 测试环境才回退 `Bundle.module`。
- 三个 Siri Remote 页面资源入口统一改用解析器。
- 公开宿主 `scripts/build-app.sh` 增加资源解析器存在性和页面不得直接使用 `Bundle.module` 的构建门禁。

## 验证计划与边界

- 私有包：资源解析优先级、缺失 App 资源回退和页面测试。
- 宿主：社区版、私有 Siri Remote 构建、`verify-app.sh`，并在隔离 SwiftPM 缓存后启动 App。
- 真机：使用新安装包实际点击 Siri Remote 入口至少一次，确认页面渲染、返回和再次进入均不崩溃。
- 本文不把 HCI 授权、遥控器语音、触摸或最终文字验收误记为本次资源修复的通过项。
