# iOS 0.8.3 无法连接 Mac App

- 时间：2026-08-04
- 状态：已修复
- 影响范围：iOS 0.8.3 与 macOS 1.6.7；首次授权和连接后错误提示
- 功能点：附近连接生命周期、授权弹窗、错误信息
- 简单描述：冷启动 active 事件会重复重启发现并打断连接/授权；同时 iOS 把 Mac 的具体操作错误覆盖成通用提示。
- 原始记录：DEBUG.md，首次记录 44338a8

## 详细过程

## Observations

- 用户真机反馈：升级到 iOS `0.8.3` 后无法成功连接 Mac App。
- 当前 `/Applications/Remote Mic.app` 的实际版本是 `1.5.1 (39)`，而不是仓库最新发布的 `1.6.7`。
- Mac `1.5.1` 对应的仓库标签中尚不存在 `PhoneRemoteServer.swift`；手机伴侣服务是在后续 `1.6.x` 才加入。
- 当前没有 Mac App 进程，也没有 Remote Mic 的 TCP 监听端口，因此当前环境没有发布 `_remotemic._tcp` Bonjour 服务。
- `0.8.2 → 0.8.3` 的 iOS 握手只新增了 Mac 发往 iOS 的可选 `appVersion` 字段；JSON 解码对缺失可选字段兼容，未改变 iOS 发出的 `hello`、密钥协商或长期身份格式。
- 历史 `PHONE REMOTE` 日志来自共享日志目录中的开发/测试运行，不能证明当前安装的 `1.5.1` 正式 App 支持手机连接。
- 用户补充：问题 Mac 的授权码弹窗最初没有及时出现，稍后弹出并允许连接后，iOS 已成功连接。
- 用户补充：连接成功后，iOS 显示“Mac 暂时无法执行这个操作，请稍后重试”。该文案只会在 iOS 收到 Mac 的安全消息 `type == "error"` 后出现，不是发现、握手或授权失败文案。
- Mac `1.6.7` 不会在纯连接成功后主动发送 `error`；只有遥控按键执行失败或手机语音启动失败会发送该消息。
- iOS 当前丢弃 Mac 返回的具体 `detail`，把辅助功能/按键失败和语音输出失败统一显示为同一条通用文案，因此仅凭界面无法判断是哪一种操作失败。

## Hypotheses

### H1: 当前启动或准备启动的是不支持手机伴侣协议的 Mac 1.5.1

- Supports: 已安装正式 App 明确为 `1.5.1`；对应标签没有手机服务端源码；当前也没有 Bonjour 服务或监听端口。
- Conflicts: 用户此前曾成功连接，说明当时可能运行的是仓库构建版、DMG 中的新 App 或其他路径下的副本。
- Test: 枚举所有 `com.hd838a.RemoteMic` App 副本，并检查当前安装二进制是否包含 `_remotemic._tcp` 与手机服务实现。

### H2: Mac 服务没有运行或没有点击“连接手机”

- Supports: 当前没有 Mac App 进程、监听端口或 Bonjour 广播；产品设计要求每次启动后由用户主动点击“连接手机”。
- Conflicts: 用户报告的是新版回归，可能已经完成了这一步；当前开发机状态也未必就是用户报告发生时的现场状态。
- Test: 使用支持手机协议的 Mac 版本启动服务，确认 `_remotemic._tcp` 出现后 iOS 是否能进入握手。

### H3: iOS 0.8.3 的 `scenePhase` 自动重连取消了正在进行的授权连接（ROOT HYPOTHESIS：授权弹窗延迟）

- Supports: 这是 `0.8.2 → 0.8.3` 唯一直接改变发现生命周期的逻辑；`!isConnected` 同时覆盖 `.searching`、`.connecting` 和 `.awaitingApproval`，而 `restartDiscovery()` 会取消当前连接；Mac 在连接关闭时会取消尚未完成的手机授权请求。该时序能解释弹窗先不出现、后来第二次连接稳定后才出现。
- Conflicts: 本地冷启动约 1 秒即可稳定显示双方相同校验码，尚未直接捕捉到第一次授权请求被取消。
- Test: 临时记录每次 `scenePhase` 变为 active 时的连接状态及是否调用 `restartDiscovery()`，验证健康的 `.connecting` 或 `.awaitingApproval` 是否被取消；实验日志不超过 5 行并在记录结果后撤销。

### H4: 已信任设备升级后的自动授权或旧会话接管异常

- Supports: 早期 Mac 手机服务端曾存在已授权旧客户端阻塞新连接的问题；升级 iOS 会中断旧进程并建立新 TCP 连接。本地全新身份可以稳定到达授权弹窗，而用户现场更可能走已有信任记录的自动授权路径。
- Conflicts: Mac `1.6.7` 已加入“新连接认证成功后接管旧会话”的修复和单元测试，且用户后来看到授权弹窗并成功连接，说明本次连接最终可以通过授权并进入 ready。
- Test: 获取问题 Mac 的 `PHONE REMOTE` 日志和 iPhone 当前状态，确认是否出现 `trusted_identity_approved`、授权弹窗以及 ready 之后的连接关闭。

### H5: 连接后的通用错误来自首次遥控按键执行失败（ROOT HYPOTHESIS：连接后 operation error）

- Supports: Mac `1.6.7` 的按键失败会发送 `detail = "Mac 需要辅助功能权限，或该按键当前不可用。"`；新安装或重签名的 Mac App 可能尚未获得辅助功能权限；iOS 会把该 detail 覆盖成用户看到的通用文案。
- Conflicts: 用户尚未说明错误出现前是否点击了普通按键或确定键；若完全没有操作，Mac 按当前代码不应发送此 error。
- Test: 确认错误出现前的首个操作，并获取问题 Mac `~/Library/Logs/RemoteMic/runtime.log` 中同一时刻的 `PHONE REMOTE`、`HID PERMISSIONS`、`PHONE VOICE FN` 和 `AUDIO` 记录。

### H6: 连接后的通用错误来自按住说话时语音启动失败

- Supports: Mac `1.6.7` 在语音已忙、音频输出未就绪或 Fn/Globe 注入失败时发送 `detail = "Mac 的语音输出当前不可用。"`；iOS 同样会覆盖成通用文案。
- Conflicts: 用户尚未说明错误前是否按住了麦克风；如果首个操作是普通按键，该假设不成立。
- Test: 确认是否由麦克风操作触发，并检查问题 Mac 同时刻的 `PHONE VOICE FN` 与 `AUDIO` 日志。

## Experiments

### E1: 核对问题 Mac 版本

- 用户补充确认：发生问题的 Mac 安装并运行的是 `1.6.7`，不是当前开发机 `/Applications` 中的 `1.5.1`。
- 结论：H1 rejected。本机旧安装副本与用户现场无关，不能作为本次根因。

### E2: 本地 Mac 1.6.7 与 iOS 0.8.3 发现及握手

- 直接运行仓库中已签名的 Mac `1.6.7 (47)`，点击“连接手机”后日志出现 `listener_ready`，进程建立 TCP 监听。
- 保持 iPhone 12 模拟器中的 iOS `0.8.3` 不变，Mac 服务启动后 iOS 自动发现并显示校验码 `85`；Mac 同时弹出相同校验码的授权对话框。
- 结论：Bonjour 发现、TCP 建连、`hello`、密钥协商和 `pairingReady` 在 `1.6.7 + 0.8.3` 组合下均可到达。H3 对“所有设备都无法冷启动连接”的解释 rejected。
- 未点击“允许连接”，因为该操作会创建持久受信任设备；因此尚未覆盖用户现场可能发生的“已信任设备自动授权”或“点击允许后收不到 ready”阶段。

### E3: 协议差异检查

- `0.8.2 → 0.8.3` 没有改变 iOS 发出的握手字段、身份签名、HKDF 参数或加密封装。
- Mac 新增的 `appVersion` 只存在于当前源码，问题 Mac `1.6.7` 不发送该字段；iOS 将其声明为可选值，实际解码已成功到达校验码阶段。
- 结论：新增版本字段不是根因。

### E4: 根据用户最新现场缩小故障边界

- 授权弹窗最终出现、用户允许后成功连接，证明问题现场最终完成了发现、TCP、密钥协商、人工授权和 ready；“始终无法连接”的描述应拆成“授权弹窗延迟”和“连接后操作失败”两个问题。
- iOS 通用错误的唯一网络入口是收到 Mac `type == "error"`；Mac `1.6.7` 只有按键失败和语音启动失败两个发送来源。
- 结论：H4 不再是当前主假设；连接后的错误必须结合触发操作或 Mac 运行日志在 H5/H6 之间判定，不能从通用 UI 文案继续猜测。

### E5: 验证冷启动 `scenePhase` 重复重启

- 在 `RemoteControlScreen` 的 `scenePhase` 回调临时加入 1 行状态输出，使用 iPhone 12 模拟器冷启动 iOS App。
- 冷启动直接记录 `phase=active state=searching connected=false`；现有条件会在 `.task` 已调用 `start()` 后立刻再次执行完整 `restartDiscovery()`，取消刚创建的浏览器并重新开始。
- 已连接后切到后台再返回依次记录 `.inactive / .background / .inactive / .active`，状态始终为 `.connected`，健康连接不会被现有条件重启。
- 结论：H3 confirmed。冷启动 active 事件确实会无意义地取消第一轮发现；不同设备调度时序下也可能在更晚的建连/授权阶段执行。诊断输出已撤销。

### E6: 核对 Mac `1.6.7` 的 operation error 与修复验证

- 直接检查 `v1.6.7` 标签源码，确认按键失败返回“Mac 需要辅助功能权限，或该按键当前不可用。”，语音启动失败返回“Mac 的语音输出当前不可用。”；没有第三个纯连接成功后自动发送 error 的路径。
- 新增状态策略与错误映射回归测试：`.searching / .connecting / .awaitingApproval / .connected` 不会因 active 重启，只有本地网络权限等待和明确不可用状态会重启；两条已知 Mac 错误映射为可操作提示，未知错误继续使用通用文案。
- iPhone 12 模拟器连接正式签名 Mac `1.6.7`：冷启动 3 秒内显示已连接测试 Mac，切到后台再返回后仍保持连接。
- 结论：授权弹窗延迟的 iOS 生命周期根因已修复；连接后实际执行失败仍需由新版 iOS 显示的具体提示或问题 Mac 日志判断是 H5 还是 H6。

## Root Cause

- 授权弹窗延迟：iOS 冷启动时 `.task` 已开始 Bonjour 搜索，紧接着的 `scenePhase == .active` 又把所有“尚未连接”的中间状态当成失败状态，取消并重建第一轮发现/连接。
- 错误信息不明确：Mac `1.6.7` 已返回具体的按键或语音失败原因，但 iOS 把两者统一覆盖为“Mac 暂时无法执行这个操作”，隐藏了用户需要处理的权限或音频信息。

## Fix

- 前台 active 只在 `.awaitingLocalNetworkPermission` 或 `.unavailable` 时完整重启发现；不再取消冷启动搜索、正在连接或等待 Mac 授权。
- 对 Mac `1.6.7` 的两条已知 operation error 使用白名单映射，分别提示检查 Mac 辅助功能/按键配置，或辅助功能/虚拟麦克风；未知错误保留通用提示。
- 不修改网络协议、长期信任、Mac 服务端和 iOS 遥控器布局。
