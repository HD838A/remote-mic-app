# 回眸无可编辑输入框时录音归为未知应用且不可见

- 日期：2026-08-27
- 状态：候选修复完成，等待真实 RC003 与第三方 App 验收
- 影响范围：macOS 1.9.13 build 141 本地回眸录音与历史页面
- 功能点：本地原始录音、前台 App 识别、回眸日期分组
- 简单描述：没有识别到可编辑输入框时，文字记录被跳过，录音没有应用元数据并显示为“未知应用”；只有录音的日期组默认折叠，用户容易误以为音频也没有保存。

## 复现与日志

现场日志来自用户提供的 `bug-回眸记录失败/runtime.log`，原始文件保留在现场 Bug 目录，不随源码提交。

2026-08-27 本地时间约 12:49–12:50 的三个会话表现为：

1. 第一个会话记录 `TRANSCRIPT CAPTURE canceled reason=discontinuous_text_change`，随后 `RECORDING ASSET saved ... bytes=55458`。
2. 第二、三个会话记录 `TRANSCRIPT CAPTURE waiting/skipped reason=initial_focus_unavailable`，随后分别 `RECORDING ASSET saved ... bytes=35002` 和 `bytes=31145`。

日志没有出现录音启动、写入或归档失败；失败集中在文字目标快照和应用信息回填阶段。

## 根因

`TranscriptCaptureSnapshot.system` 只有在同时取得辅助功能焦点元素、文本值和选区后才返回快照，因此“应用身份”和“可编辑输入框”被绑定在同一个成功条件上。文字捕获失败时，`BridgeAppModel.archiveCapturedTranscript` 不会执行，录音 manifest 也就无法获得应用名称和 Bundle ID，界面将其归入 `__unknown__`。

历史页面的默认展开逻辑只选择文字日期组；当筛选到只有录音的应用时，没有任何文字日期组可以展开，录音内容保持折叠。

## 修复

- 新增前台 App 元数据回退值，在录音会话开始时写入待提交 metadata；文字捕获成功后仍用输入框所属 App 覆盖回退值。
- 没有可编辑输入框时不伪造文字，但录音仍保存并按前台 App 归类；若前台 App 也不可得，记录明确的回退不可用日志。
- 回眸页面在首次显示或切换应用后，同时展开最新文字日期组和最新录音日期组，录音-only 历史可直接看见。

## 验证

- `swift test --filter 'RecordingAssetStoreTests|TranscriptCaptureCoordinatorTests'`：15 项通过。
- 新增 `recordingOnlySessionKeepsApplicationMetadata`，验证没有文字记录时录音 manifest 仍保留应用名称和 Bundle ID。
- `git diff --check`：通过。

## 验证边界

自动化使用本地录音 writer 和可控快照，不能证明真实 RC003、Nearby iPhone、Apple Watch、Web 遥控器或第三方 App 的前台 App 识别。签名候选包仍需人工验证：无可编辑输入框时录音可播放、应用名称和图标正确；有可编辑输入框时文字与录音仍合并为同一条记录；切换 App、前后台、跨日期和关闭开关不产生回归。
