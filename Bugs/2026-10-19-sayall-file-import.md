---
title: Finder 键位方案导入时序修复
template: doc
lang: zh
---

## 结论

候选修复。Finder 文件入口只调用键位方案导入。
真实签名安装和首次完整旅程仍待验收。

## 证据与根因

| 触发条件 | 错误行为 | 确认证据 |
| --- | --- | --- |
| 设置窗口已挂载后打开文件 | 请求没有消费 | 生产 SettingsView 挂载测试在修复前失败 |
| 从其他页面进入键位方案 | 页面可能漏收导入请求 | 私有导入视图只监听 requestedOperation 的变化 |
| 深链路径恰好以 .sayall 结尾 | 可能同时触发文件入口 | 原入口没有检查 isFileURL |

`@Published` 在属性写入前发布事件。
旧订阅忽略事件值，再读取属性，因此会读到旧请求。
页面尚未挂载时提交操作，也会错过导入视图的监听。
已挂载页面的重复请求还依赖 SwiftUI `.task(id:)` 重启。
该重启不是稳定的请求消费边界。
合并主线后的 CI 复现了第二次请求保留在 `pendingRequest` 的错误。

## 最小修复

- RemoteMicApp.swift 只接收本地 .sayall 文件。
- MacroFeatureIntegration.swift 限定键位方案范围，并拒绝非文件 URL。
- SettingsView.swift 在状态更新后路由请求。
- 键位方案页面挂载后，再提交导入操作。
- 页面已经挂载时，后续 Finder 请求同步消费，避免依赖 SwiftUI `.task(id:)` 重启。
- 未包含私有模块时，显示现有设置页内的不可用提示。
- RemoteMicRootView.swift 只传递请求，不改变向导完成门槛。
- Info.plist 注册文件类型；两种语言补齐不可用提示。

原预览、取消、保存和会员校验继续使用现有实现。
不修改音频、蓝牙、HID、语音键或配置格式。
入口日志只表示接收和提交，不表示保存成功。
保存结果继续由共享导入控制器记录。

## 验证与边界

| 检查 | 结果 |
| --- | --- |
| 公开宿主完整测试 | 待当前修复的 CI 复验 |
| 私有构件宿主完整测试 | 待当前修复的 CI 复验 |
| 最终文件入口定向测试 | 本地修复前失败；当前修复待 CI 复验 |
| 市场 Schema 与合同校验 | 通过 |
| Apple Silicon Release App | 构建和 verify-app 通过 |
| 生产页面交互 | 预览全部绑定；取消后仍只有默认方案 |
| 自动化首次向导隔离 | 未完成向导时保留请求，不打开编辑器 |
| 签名安装、完整向导、确认保存和重启 | 未执行 |
| Plus 和保存前撤销权益 | 未执行真实会员验收 |
| CI | #695 合入后的 #693/#694 合并测试复现失败；当前修复待复验 |

最终定向命令：`swift test --disable-keychain --filter RemoteMicTests.ButtonProfileFileOpeningTests`。
私有运行需显式注入已校验的统一构件，并装配资源 Bundle。

先前 CI 的失败来自 Finder 请求消费时序，不是测试装配问题。
失败发生在第二次请求仍留在 `pendingRequest`。
当前修复直接消费已挂载页面的请求。

市场提交为 `ef39fa12d8e5b23c9d3e198e525855b26ab03515`。
私有构件源码提交为 `eb433a5776568efb4008018f909cd6f3544f44a2`。
公开宿主基线为 `b62f40ebb9751911bf71544a39af5c8b199af2db`。

生产截图使用隔离数据和现有交互入口。
App 版本为 2.0.0，Build 为 251，窗口为 1020 × 772。
截图为 JPEG，2040 × 1544，中文浅色。
SHA-256 为 `fc89e381433628332c618ac932c2939d23ec4a1e2211bd2d2588a600630c76e8`。
截图位置：`Screenshots/design-drafts/sayall-file-import/import-preview-macos-zh-light.jpg`。
该截图只证明生产页面预览，不证明 Finder 或新安装旅程。

请求只在当前进程暂存。退出后需重新双击文件。
同批文件只处理首个 .sayall；向导期间采用最新请求。
取消、失败和重试仍需按测试手册完成签名安装验收。
