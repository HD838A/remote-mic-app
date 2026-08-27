# Mac 本地原始录音资产

## 用户可见行为

- “回眸”页面新增独立的“保存原始录音”开关，默认关闭；它与“记录回眸”文字开关互不影响。
- 开启后，Mac 已接收的 16 kHz、单声道 PCM 会在语音会话结束时编码为本地 M4A/AAC，并按本机日期和统一 session ID 与回眸文字关联。
- 录音记录显示目标应用图标与名称、时间和时长，支持播放、导出、在 Finder 中显示和移入废纸篓删除。
- 只有录音没有文字时也会保留“仅录音”条目；关闭任一开关不会删除已经保存的另一类数据。

## 范围与边界

本期只保存进入 Mac 音频管线后的 PCM，不保存遥控器内部未经解码的 ADPCM 字节；不做 iPhone/Watch 独立录音、云端上传、跨设备同步或 MCP 音频返回。MCP 仍只读取文字历史。

录音资产位于：

`~/Library/Application Support/RemoteMic/Recordings/v1/<YYYY-MM-DD>/<session-id>/`

目录权限为 `0700`，manifest 权限为 `0600`。录音先写入 `.partial.m4a`，会话正常结束后改名为 `original.m4a` 并原子写入 `manifest.json`。删除操作使用 macOS 废纸篓，不永久删除用户数据。

## 实现位置

- `RecordingAssetStore.swift`：资产目录、manifest、校验和、路径安全及可恢复删除。
- `BridgeAppModel.swift`：统一 RC003、Nearby iPhone、Watch、Web 音频入口，管理录音会话、回放和导出。
- `TranscriptCaptureCoordinator.swift`：把文字捕获与录音共用 session ID；录音开启时即使文字开关关闭，也会读取安全目标的应用元数据。
- `TranscriptHistorySection.swift` / `SettingsView.swift`：时间线、应用筛选、日期折叠和录音操作。
- `AppSettings.swift` 与本地化资源：默认关闭的独立开关及中英文文案。

## 验证状态

SwiftPM 构建和录音存储自动化已通过；真实 RC003、Nearby iPhone、Apple Watch、Web、第三方输入法、前后台、磁盘不足和长时间录音仍需按 [`Testing/LocalRecordingAssets.md`](../../Testing/LocalRecordingAssets.md) 完成人工验收。
