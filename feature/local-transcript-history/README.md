# 本地语音转写记录

## 为什么开发

用户完成语音输入后，如果没有使用 AI 整理，转写文字只存在于目标应用中，无线麦自身无法按时间回看。该功能提供一个默认关闭、完全本地的独立记录入口，方便用户按应用和日期查看自己实际输入过的文字。

## 用户功能

- 在侧边栏“统计”下方打开“语音记录”，并开启“保存语音记录”。
- 新完成的语音输入会按目标 App 和语音结束时的本机日期分组。
- 应用列表和当前应用详情显示系统安装的真实 App 图标。
- 支持复制单条记录、删除单条记录、删除当前 App 的全部记录和删除全部记录。
- 关闭开关只停止保存新记录，不删除已有记录。

## 范围与非目标

本功能只接入 Mac 已有的公共语音开始/结束生命周期，不修改蓝牙、ATVV、PCM、Fn 注入、iOS、Watch 或网页协议。它不提供录音回放、云同步、全文搜索、AI 整理、跨设备同步或服务端备份。

## 关键设计与开发过程

语音开始时通过 Accessibility 保存安全可编辑目标的最小快照；语音结束后最多等待 8 秒，只接受原选区处的一段连续新增或替换，并在文字稳定约 900ms 后保存。若已观察到合法候选，用户快速发送、切走焦点或立即开始下一段语音时会先结算该候选；尚未观察到候选、目标 App 改变或周围文字发生无关变化时仍放弃本次捕获。密码、Token、搜索框、地址栏和设置类输入区域不会记录。

数据使用版本化 JSON，路径为：

`~/Library/Application Support/RemoteMic/Transcripts/v1/<app-key>/<YYYY-MM-DD>.json`

目录权限为 `0700`，正文文件权限为 `0600`，原子写入。删除单条记录会先把原日期文件移到 macOS 废纸篓再重写剩余内容；按 App 或全部删除会把对应目录移到废纸篓。

详细研究和实施计划保存在私有产品资料库，不复制到公开源码仓库。

## 涉及文件

- `Sources/RemoteMic/AppSettings.swift`：保存默认关闭的本地记录开关。
- `Sources/RemoteMic/TranscriptCaptureCoordinator.swift`：安全输入框快照、文字稳定等待和本次差异提取。
- `Sources/RemoteMic/TranscriptArchiveStore.swift`：按 App/日期落盘、加载和可恢复删除。
- `Sources/RemoteMic/BridgeAppModel.swift`：接入公共语音生命周期并向界面发布记录。
- `Sources/RemoteMic/TranscriptHistorySection.swift`：带真实 App 图标的应用列表、日期、复制和删除界面。
- `Sources/RemoteMic/SettingsView.swift`：在统计下方提供独立“语音记录”侧边栏页面。
- `Resources/*/Localizable.strings`：中英文界面文字。
- `Tests/RemoteMicTests/Transcript*Tests.swift`：存储、捕获和 Feature Flag 自动化。

## 隐私与兼容边界

保存内容仅包括本次新增转写文字、开始/结束时间、目标 App 名称、Bundle ID、输入来源和本地日期元数据。不会保存音频、输入框全文、前后文、窗口标题、文档名、URL、设备标识或 API Key，也不会上传。功能不依赖私有 AI 组件；未安装私有组件或没有 API Key 时仍可运行。

Accessibility 不提供统一的跨应用“语音结果事件”，因此当前实现只覆盖能够读取文本值和选区的安全标准输入区域。使用自绘编辑器、Web contenteditable、跨进程输入面板，或文字出现前就切换目标时可能放弃保存，避免误记录其他内容。

## 验证与当前状态

当前状态：修复与独立页面完成，完整自动化和 `1.8.5 (68)` Release App 构建通过，等待真实语音流程人工验收。

自动化 236 项、22 个 Suite 全部通过，覆盖按 App/日期写入、排序、`0600/0700` 权限、可恢复删除、默认关闭及持久化、连续文字提取、快速发送、连续语音、恢复非空原稿不误存、敏感目标拒绝、无候选焦点变化取消和关闭开关取消捕获。Release App 的深度签名、版本、Apple Silicon 架构和无私有 AI 包构建均已校验。人工测试步骤见 [`Testing/LocalTranscriptHistory.md`](../../Testing/LocalTranscriptHistory.md)。

尚未完成 RC003、Nearby iOS、网页版、真实第三方 App、前后台、跨日和不同系统版本验收，因此不能标记为已完成或已真机通过。
