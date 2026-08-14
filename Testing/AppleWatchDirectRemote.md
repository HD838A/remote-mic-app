# Apple Watch 直连遥控与收音测试手册

## 适用版本与分支

- Mac App `1.8.23` 候选分支，包含 Apple Watch 专用连接入口、Watch BLE 服务和 Phone Bonjour 发布自恢复。
- 与当前附近协议兼容的 iPhone / Apple Watch App。

## 测试前准备

1. 一台实际测试 Mac、一块真实 Apple Watch 及其配对 iPhone。
2. Mac 已安装并选择 MiRemoteV 2ch，准备一个真实语音输入工具。
3. 记录 Mac、watchOS、iOS 和各 App 版本；测试前退出并重新启动 Mac App。
4. 首轮测试前清除 Mac 的受信任移动设备，以便观察两位码授权。

## 用例一：专用入口与按需监听

1. 启动 Mac App，打开“连接与语音”。
2. 确认顺序为 iPhone、Apple Watch、网页版。
3. 不点击入口，观察状态和日志。
4. 点击“连接 Apple Watch”，再点击“取消等待”。

预期：Mac 启动时不自动监听；用户点击后日志出现 `PHONE REMOTE service_published`、`WATCH BLE advertising`，Watch 入口显示等待状态；取消后日志出现 `PHONE REMOTE disabled_by_user`、`WATCH BLE stopped`，iPhone 与 Watch 两行共同恢复“尚未开启”。连接页在仓库要求的最小检查窗口下没有裁切、重叠或窗口几何变化，中文文字不低于 12pt。

失败：启动即出现用户开启日志、缺少 Watch 行、顺序错误、等待无法取消、旧授权弹窗残留或页面裁切。

## 用例二：发现、授权与信任

1. 从 Watch App 发起连接。
2. 核对 Watch 与 Mac 的两位码，允许连接。
3. 断开后重新连接，再清除受信任设备后重试。

预期：Mac 授权说明明确指向 Apple Watch；首次需要允许，未清除信任时可自动授权，清除后必须重新确认。普通界面不显示密钥、身份指纹或底层网络细节。

失败：Watch 一直停在“正在连接 Mac”、Mac 不弹授权、校验码不一致、清除信任无效或授权说明仍只写 iPhone。

## 用例三：遥控按键与映射

1. 逐个测试 Watch 提供的全部按键。
2. 在 Mac 为其中一个按键配置单击、双击和长按动作，再分别触发。
3. 同时回归 iPhone 和实体遥控器的对应按键。

预期：Watch 按键进入现有白名单、手势识别和动作映射链路；没有漏发、重复、错位或绕过本机配置。iPhone 和实体遥控器行为不变。

失败：按键卡住、动作执行两次、映射不生效、不同来源互相污染手势状态或出现任意命令执行能力。

## 用例四：Watch 麦克风

1. 在 Watch 开始收音，说话 10 秒后停止。
2. 重复 1、3、5 分钟会话，并测试中途离开 App、断开网络和取消等待。
3. Watch 停止后立即使用已连接 iPhone 开始 10 秒收音；再反向从 iPhone 切回 Watch。
4. 观察 MiRemoteV 2ch、真实语音输入工具和 Mac 日志中的 `MOBILE VOICE` 开始/停止来源。

预期：音频进入现有移动语音路径，开始与停止各一次；停止、断线或取消等待后不再输出，虚拟麦克风和系统语音键状态正常释放。Watch 停止不得延迟数十秒，iPhone 与 Watch 只能停止自己的会话；被另一设备占用时客户端显示明确占用提示，不误报辅助功能或虚拟麦克风故障。

失败：Mac 无音频、首句明显丢失、停止后继续收音、停止延迟数秒以上、切换来源后仍永久占用、会话重复、虚拟麦克风占用不释放或第三方工具没有收到输入。

## 用例五：客户端接管

1. 先连接 iPhone，再由 Watch 连接同一台 Mac。
2. 反向重复。
3. 保持一个附近客户端时建立网页版会话。

预期：新的已授权附近客户端安全接管旧会话，无需重启 Mac；当前只保留一个 iPhone 或 Watch 附近客户端，网页版保持独立。iPhone、Watch 和 Web 的语音来源分别记录，任一路的延迟停止不会结束另一来源的当前会话。

失败：旧客户端永久占用、必须重启、按键或音频跨会话泄漏，或网页版被附近连接意外关闭。

## 稳定功能回归

- iPhone 附近连接、长期信任、按键和语音保持兼容。
- 网页版邀请、二维码、按键和语音保持兼容。
- 实体遥控器、按键映射、虚拟麦克风、Onboarding 和更新入口不变。
- 等待状态使用提醒色，只有真实成功状态使用成功色；浅色、深色、增强对比度和降低透明度下均可辨认。

## 日志收集

保存 Mac `~/Library/Logs/RemoteMic/runtime.log` 中问题时间段，重点检查 `PHONE REMOTE enabled_by_user`、`listener_ready`、`service_published/service_publish_timeout/service_removed`、`WATCH BLE starting/service_add_requested/advertising/stopped`、`MOBILE VOICE started/stopped/start_rejected/stop_ignored`、授权结果和 `disabled_by_user`。Watch 端从 Watch/iPhone App 的诊断入口导出合并日志。不得上传音频、校验码、密钥、身份指纹、地址或账号信息。

## 自动化、代理实测和用户实测边界

自动化覆盖组件协议、Mac 编译、入口回归、iPhone/Watch 语音来源隔离和占用错误分类；代理无法替代真实 Apple Watch 的权限、无线链路、麦克风、前后台、BLE 实时吞吐和实际语音工具验收。任何未执行的真机用例都必须明确标记为未验收。
