# DeepSeek 语音结束后整理 MVP 开发记录

## 1. 开发目标确认

本次目标不是替换长期独立语音输入方案，而是完成一个可以关闭、失败可回退、只需要一个模型 API 的试验版本：

1. 保留现有遥控器、手机、网页遥控器和虚拟麦克风链路；
2. 豆包输入法继续负责语音识别和实时上屏；
3. 语音结束后观察目标输入框，等待本次文字出现并稳定；
4. 单次调用 DeepSeek 整理本次文字；
5. 只有目标和文字完全未变时才做局部替换；
6. 任何失败都保留豆包原文。

详细产品研究和长期计划继续保存在私有 marketing 仓库，本文件只记录公开实现事实和验证结果。

## 2. 精确代码接入点

为了不改变共享蓝牙协议、PCM 路由和移动端协议，本功能只接入公共语音会话边界：

- [`Sources/RemoteMic/BridgeAppModel.swift`](../../Sources/RemoteMic/BridgeAppModel.swift)
  - `beginVoiceSessionIfNeeded()`：功能开启时捕获目标快照；
  - `endVoiceSessionIfNeeded()`：开始等待豆包文字稳定；
  - `stop()`：取消尚未完成的等待和请求；
  - 发布设置页所需状态，并提供 Key、术语和手动复制操作。
- [`Sources/RemoteMic/AppSettings.swift`](../../Sources/RemoteMic/AppSettings.swift)
  - 只保存默认关闭的实验开关；
  - 不保存或导出 API Key。
- [`Sources/RemoteMic/SettingsView.swift`](../../Sources/RemoteMic/SettingsView.swift)
  - 在左侧侧边栏增加独立“AI 整理”入口；
  - 独立页面集中展示运行状态、工作流程、模型、凭证、隐私边界、术语和格式策略；
  - 从连接页面移除 AI 设置，不改变连接、映射、统计、权限和关于页面的职责。
- [`Sources/RemoteMic/RemoteMicApp.swift`](../../Sources/RemoteMic/RemoteMicApp.swift)
  - 只订阅真实后整理的 DeepSeek 请求状态；
  - 请求开始时显示全局 HUD，请求结束时隐藏，不激活主设置窗口。

没有修改：

- `ATVVProtocol.swift`；
- `XiaomiBluetoothBridge.swift`；
- `AudioOutput.swift` 的 PCM 和设备逻辑；
- iOS 或网页遥控器协议。

## 3. 新增组件

### `PostDictationPolishCoordinator`

文件：[`Sources/RemoteMic/PostDictationPolishCoordinator.swift`](../../Sources/RemoteMic/PostDictationPolishCoordinator.swift)

职责：

- 捕获前台 PID、App 名称、Bundle ID、焦点 AX 元素、全文和选区；
- 排除安全输入框和不支持精确读写的元素；
- 冻结选区前后各最多 100 个可见字符；
- 每 125ms 观察一次文字，首次变化后等待约 900ms 稳定；
- 使用原始选区约束计算本次 UTF-16 范围；
- 以 generation 隔离旧会话，并在新会话、关闭功能或退出时取消；
- DeepSeek 返回后重新校验前台 App、焦点元素、完整文字和选区；
- 使用 `kAXSelectedTextRangeAttribute` 和 `kAXSelectedTextAttribute` 只替换本次文字；
- 精确写入失败时保留原文，并允许用户主动复制整理结果。

### `DeepSeekTextPolishingClient`

文件：[`Sources/RemoteMic/DeepSeekTextPolishingClient.swift`](../../Sources/RemoteMic/DeepSeekTextPolishingClient.swift)

职责：

- 固定调用 `https://api.deepseek.com/chat/completions`；
- API 请求标识固定为 `deepseek-v4-flash`；
- `stream = false`、低 temperature、JSON response format；
- 固化 `post_dictation_polish_v1` System Prompt；
- User Message 使用结构化 JSON，明确上下文只读且只有 `currentDictation` 可修改；
- 只接受唯一字段 `{"refinedText":"..."}`；
- 拒绝空结果、未知字段、代码围栏、异常扩写、数字丢失和受保护术语丢失；
- 日志不记录任何实际文字或凭证。

### `DeepSeekCredentialStore`

文件：[`Sources/RemoteMic/DeepSeekCredentialStore.swift`](../../Sources/RemoteMic/DeepSeekCredentialStore.swift)

- Keychain service：`com.hd838a.RemoteMic.deepseek`；
- account：`deepseek-api-key`；
- 支持保存、更新、读取和删除；
- 使用仅本机可用的 Keychain 可访问级别。

### `ProgrammingTermStore`

文件：[`Sources/RemoteMic/ProgrammingTermStore.swift`](../../Sources/RemoteMic/ProgrammingTermStore.swift)

- 在 Application Support 下保存版本化 JSON；
- 支持系统名、项目名、分支、命令、路径和标识符；
- 每条包含标准写法、口述别名、大小写、保护和启用状态；
- 请求最多使用 50 条启用术语，总术语载荷不超过约 8KB；
- 不扫描项目、Git、终端、剪贴板或其他 App。

### `PostDictationHUDController`

文件：[`Sources/RemoteMic/PostDictationHUDController.swift`](../../Sources/RemoteMic/PostDictationHUDController.swift)

- 使用非激活、无边框、鼠标穿透的 `NSPanel` 承载 SwiftUI HUD；
- 窗口加入所有 Space，并支持覆盖全屏 App；
- 优先根据当前键盘焦点窗口所在屏幕的 `visibleFrame` 定位到 Dock 上方中央，系统无法确定时才回退到鼠标屏幕，不硬编码单一显示器坐标；
- 只在状态为 `.requesting` 且状态键为真实整理请求时显示，连接测试不会触发；
- 主题色取自 App Logo 的暖橙和星光黄，深暖灰背景保证跨 App 对比度；
- 显示和隐藏使用短暂淡入淡出，退出 App 时立即移除。

## 4. 关键开发决策

### 只观察豆包已经写入的文字

MVP 不接入第二套 ASR，也不上传音频给 DeepSeek。这样可以先验证文本整理、安全替换和术语能力，同时保持现有实时上屏体验。

### 上下文只读由两层保证

Prompt 声明 App 信息和前后文只读；本地写入层只持有本次 Diff 的 `newRange`。即使模型返回了上下文，App 也没有覆盖全文的写入路径。

### 使用原始选区约束 Diff

初始实现只使用最长公共前缀和后缀。开发测试发现，当原选区和新文字拥有相同后缀时，例如“旧内容”替换为“新内容”，纯 Diff 会把变化缩小为“旧”到“新”，无法证明整个原选区由本次语音替换。

最终实现把语音开始时的原始选区作为硬边界：选区前缀和后缀必须逐字保持，更新后的中间区域才是本次文字。这同时覆盖光标插入和选区替换，并避免修改两侧上下文。

### 自动列表首期关闭

自动列表已经是确认需求，但本次重点是文字范围和安全写入。请求固定发送 `automaticList = false`，Prompt 明确禁止把“第一点、第二点”自动转为 Markdown 列表。

### 失败时不自动使用剪贴板

自动覆盖剪贴板或发送 Command-V 可能破坏用户状态。本版只在已经得到结果但精确 AX 写入失败时展示“复制整理结果”，必须由用户主动点击。

## 5. 开发中发现并修正的问题

1. **原选区与公共后缀歧义**：改为使用原始选区约束变化范围，并增加选区替换测试。
2. **本地化键格式不符合仓库规范**：将 camelCase 本地化键改为小写 snake_case，现有本地化一致性测试恢复通过。
3. **功能关闭时共享链路应尽量无行为变化**：在 `BridgeAppModel` 会话入口先检查 Feature Flag，关闭时不创建或启动协调器会话。
4. **精确写入仍可能被第三方控件拒绝**：增加只由用户触发的复制结果兜底，不自动修改剪贴板。
5. **设置页状态无法在其他 App 中被看到**：新增只在 DeepSeek 实际请求阶段显示的全局 HUD；详细状态仍留在设置页用于排障。

## 6. 测试与验证

新增测试：

- [`Tests/RemoteMicTests/PostDictationPolishCoordinatorTests.swift`](../../Tests/RemoteMicTests/PostDictationPolishCoordinatorTests.swift)
  - 光标插入；
  - 原选区替换；
  - UTF-16 范围；
  - emoji 和组合字符；
  - 前后 100 个可见字符；
  - Feature Flag 默认关闭和持久化。
- [`Tests/RemoteMicTests/DeepSeekTextPolishingClientTests.swift`](../../Tests/RemoteMicTests/DeepSeekTextPolishingClientTests.swift)
  - 非流式参数；
  - 结构化 App、上下文、术语和格式策略；
  - 严格 JSON；
  - 数字和受保护术语检查。
- [`Tests/RemoteMicTests/ProgrammingTermStoreTests.swift`](../../Tests/RemoteMicTests/ProgrammingTermStoreTests.swift)
  - 保存、读取、禁用和删除。
- [`Tests/RemoteMicTests/PostDictationHUDControllerTests.swift`](../../Tests/RemoteMicTests/PostDictationHUDControllerTests.swift)
  - 真实整理请求与连接测试的显示边界；
  - 主显示器和偏移外接显示器的底部居中定位。

执行结果：

- `swift test --jobs 4`：159 项测试通过；
- `CONFIGURATION=release ./scripts/build-app.sh`：通过；
- `./scripts/verify-app.sh 'dist/Remote Mic.app'`：通过；
- 中英文 `Localizable.strings`：`plutil -lint` 通过；
- `git diff --check`：通过；
- staged diff API Key 模式扫描：通过；
- 真实 DeepSeek API：`deepseek-v4-flash` 请求成功；`deepseek-v4-fash` 返回不支持模型错误。

## 7. 当前边界与下一步

自动化测试不能证明真实豆包输入法、Accessibility 或第三方输入控件已经兼容。当前状态因此是“等待人工验收”，不能表述为已完成真实输入流程验收。

下一步按照 [`testing.md`](./testing.md) 验证：

1. Feature Flag 四种状态；
2. TextEdit、Codex、浏览器和聊天输入框；
3. RC003、附近 iPhone 和网页遥控器；
4. 改口、否定、数字、上下文和原选区；
5. 分支名、路径和符号口述；
6. 焦点变化、用户继续编辑、新会话和网络失败；
7. 设置页面尺寸、滚动和全部入口。
8. 全局 HUD 的跨 App、全屏、多屏、鼠标穿透和不抢焦点行为。
