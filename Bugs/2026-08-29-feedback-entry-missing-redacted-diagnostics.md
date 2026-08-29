# Issue #102：反馈入口缺少脱敏诊断上下文

- 时间：2026-08-29
- 状态：候选修复完成；自动化通过，等待真实浏览器和 SayAll 工作台接收验收
- 影响范围：macOS 无线麦SayAll.app“关于”页的问题反馈入口
- 功能点：反馈链接、脱敏诊断摘要、运行日志入口
- 简单描述：反馈入口只携带 `source=mac`，无法自动提供版本、系统架构、权限及核心运行状态。
- 原始记录：GitHub Issue #102、`TODO.md` 反馈入口条目、`Testing/IssueFeedbackLink.md`、`AppLinks.swift`、`SettingsView.swift`

## 复现

在基础提交 `00b6d8a4a95fd5e73272c6115164b8003f12b2ed` 检查“关于”页反馈链接：

1. `SettingsView` 直接使用固定的 `AppLinks.feedback`。
2. `AppLinks.feedback` 固定为 `https://my.sayall.app/api/guest-entry?source=mac`。
3. `FeedbackLinkTests` 明确断言查询参数只有 `source=mac`。

因此任意 Mac、权限或连接状态打开的 URL 都完全相同，Issue #102 所需上下文稳定缺失。基础测试 `swift test --filter FeedbackLinkTests` 通过 2 项，证明现有测试固化的是旧行为，不代表需求已满足。

## 日志证据

本机 `~/Library/Logs/RemoteMic` 当前只有 `plugin-runtime.log`，没有可用于还原反馈点击的 `runtime.log`；现有反馈入口本身也不记录点击事件。该问题不依赖现场时序，固定 URL 与入口代码已经足以确定缺口。

既有 [`2026-08-24-runtime-log-operational-quality.md`](./2026-08-24-runtime-log-operational-quality.md) 证明运行日志已有实例、版本、轮转和稳定字段，但日志仍可能包含用户运行现场上下文，不适合未经用户检查自动上传。

线上只读探测确认 `guest-entry` 接收附加参数后仍返回 `302 Location: https://my.sayall.app/`，重定向地址不保留查询参数。Mac 端已经完成字段发送，但独立维护的工作台能否在 guest session 中消费或保存这些字段，仍必须由 Web 前端/服务端仓库配套验证；本 PR 不读取或修改该仓库。

## 根因

最初实现只解决最低权限工作台入口，未定义 Mac 到反馈页的脱敏上下文字段；关于页也没有让用户主动查看日志的就近入口。固定链接和旧测试共同导致后续权限、连接、音频与按键状态无法随反馈提交。

## 修复

- 反馈 URL 增加版本化字段白名单，只传递 App 版本/Build、macOS 三段版本、CPU 架构、蓝牙/输入监控/辅助功能权限，以及连接、音频、按键和日志可用性的枚举或布尔摘要。
- 诊断模型没有账号、Token、设备名称/标识、IP、蓝牙地址、输入文字、音频、路径或动态口令字段；版本字符串额外规范为短稳定 token。
- 关于页按当前实时状态生成链接，并复用现有“打开日志文件夹”能力提供可选日志入口。日志不会自动上传，界面明确要求用户检查后主动附加。
- 不读取其他 App 数据，不改变反馈工作台权限和服务端行为。

## 验证

- `swift test --filter 'FeedbackLinkTests|LocalizationTests'`：9 项通过，覆盖完整白名单、敏感字段缺失、关于页入口和中英文资源一致性。
- `swift test`：418 项通过，0 失败。
- `./scripts/test.sh`：44 项自检通过，Swift Package 构建通过。
- 生产 `SettingsView` 截图 harness 在 `800 × 650` 中文浅色状态渲染全部 7 个侧边栏页面；关于页反馈卡、两个操作和纵向滚动区域没有横向裁切。当前直接运行 SwiftPM debug executable 时本地化资源显示 key，因此该截图只证明布局，不能替代签名 App 中英文文案验收。
- 线上 `curl` 只读探测：最低权限入口仍返回 `302` 并建立匿名 guest Cookie；当前 `Location` 不含诊断参数，工作台接收链路不能由本仓库单独证明。
- `git diff --check`：通过。

## 验证边界

自动化可证明本地 URL 结构和源码入口，不会启动真实默认浏览器，也不能证明独立维护的 SayAll 工作台已展示、保存这些参数。必须按 `Testing/IssueFeedbackLink.md` 使用中英文真实 App 完成浏览器跳转、参数接收、日志入口和反馈提交验收；日志内容是否适合附加仍由用户逐次检查。
