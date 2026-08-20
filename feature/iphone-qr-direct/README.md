# iPhone 二维码局域网直连

## 为什么开发

部分 iPhone 的本地网络浏览器会进入可用状态但长期返回零个 Bonjour 结果。二维码直连让用户绕过发现阶段，同时保留原有自动发现作为兜底。

## 用户功能

用户在 Mac 主动开启“连接手机”后，连接页和首次使用向导显示短时二维码。iPhone 扫描后优先直接连接二维码中的当前局域网端点，随后继续原有安全握手、两位确认码、长期信任、按键和语音流程。

## 范围与非目标

- 二维码只为 iPhone 增加可选的端点获取方式，不替换 Bonjour/P2P。
- 缓存只属于当前 Mac 监听周期；监听停止、内部重建或 Mac 重启后，旧监听 ID 不再有效。
- Watch 不扫描二维码，不增加必填协议字段，继续使用 Bonjour/P2P 和 BLE 回退。
- 不提供跨互联网连接，不开放路由器端口，不把二维码凭证写入日志。

## 关键设计与涉及文件

- `SayAllMacRemote` 的 `PhoneRemoteServer` 生成当前监听周期、端口、候选本机地址和一次性邀请；邀请字段全部可选。
- `Sources/RemoteMic/BridgeAppModel.swift` 只把当前邀请发布给界面。
- `Sources/RemoteMic/PhoneRemoteInvitationView.swift`、`SettingsView.swift` 和 `OnboardingView.swift` 展示二维码。
- iOS 侧解析二维码、优先连接候选端点、在成功后仅缓存监听 ID 与地址，并在失败时回退现有发现。

## 隐私与兼容边界

二维码包含短时局域网连接凭证，应像临时邀请码一样处理。App 日志只记录连接方式和结果，不记录二维码、地址、端口或任何邀请字段。没有邀请字段的 Watch、旧 iOS 和现有 Bonjour 客户端继续使用原协议。

## 验证与当前状态

共享组件自动化已覆盖邀请有效期、监听周期、一次性消费和 legacy 兼容；Mac 全量测试、Release App 构建和启动门禁已通过，继续按 [测试手册](../../Testing/iPhoneQRDirectConnection.md)进行真机验收。

状态：代码与自动化验证完成，等待真实 iPhone、Apple Watch、Mac 网络和音频验收。
