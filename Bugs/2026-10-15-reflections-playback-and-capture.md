# 回眸播放、应用识别和删除入口问题

- 日期：2026-10-15
- 状态：候选修复完成，真实微信和无线麦 App 验收待执行
- 影响范围：macOS 回眸页面的录音播放、应用显示、文字捕获和关联记录删除

## 问题证据

1. 录音行只有一个“播放”按钮。`BridgeAppModel.playRecording` 每次都停止旧播放器并从文件开头创建新播放器。页面没有暂停和停止状态。
2. 录音会话开始时使用 `FrontmostApplicationMetadata.current(excludingBundleIdentifier: Bundle.main.bundleIdentifier)`。当前台目标是无线麦自身时，元数据被主动丢弃，录音清单没有应用名称和 Bundle ID，页面显示“未知应用”。历史清单已经缺少这两个字段时，无法从录音文件恢复原应用。
3. 文字捕获的启用条件同时依赖“记录回眸”和“保存原始录音”。这会让两个用户开关产生隐式耦合。文字捕获应只由“记录回眸”控制。
4. 关联文字行同时显示文字删除按钮和录音删除按钮，用户看到两个删除图标。产品行为要求一条关联记录使用一个删除入口。

## 修复

- 使用 `AVAudioPlayerDelegate` 管理播放完成状态。再次点击同一条记录可暂停或继续，播放中的记录显示停止按钮；切换其他记录前停止上一条播放。
- 不再排除无线麦自身的前台 Bundle ID。录音回退元数据现在保留当前前台 App；回眸页面还会用公开 `NSWorkspace` 和 Bundle 信息补全已有清单中的空应用名称。
- 文字捕获只读取 `localTranscriptHistoryEnabled`。关闭原始录音只停止音频资产，不改变文字捕获。
- 关联文字和录音使用一个删除图标。确认后文字文件和关联录音目录分别移入 macOS 废纸篓；独立录音仍保留录音行的删除入口。

## 验证

- `swift test --disable-keychain --filter 'TranscriptCaptureCoordinatorTests|RecordingAssetStoreTests|SettingsPageRegressionTests'`：77 项通过。
- `swift test --disable-keychain`：868 项、68 个套件通过。
- `scripts/verify-repository-governance.sh origin/main`：通过。
- `git diff --check`：通过。

## 验证边界

自动化验证了源码结构、录音存储和文字捕获回归。尚未在真实微信 App、无线麦 App、真实录音文件和播放窗口中完成暂停、继续、停止、应用名称及关闭原始录音后的文字输入验收。历史清单已经同时缺少名称和 Bundle ID 时，系统没有可安全使用的来源，不能自动推断原应用。
