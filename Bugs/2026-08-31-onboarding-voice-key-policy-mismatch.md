# Onboarding 允许 Command 导致第三方语音工具不提交文字

- 时间：2026-08-31
- 状态：修复完成，等待 PR CI 与真实设备验收
- 影响范围：SayAll macOS 1.9.19 (172)，Onboarding 语音工具选择与语音测试；豆包、微信输入法及其他依赖按键配置的第三方语音工具
- 功能点：Onboarding 语音触发键、第三方输入法配置、首次使用诊断

## 现象与复现

用户在 Onboarding 选择微信输入法，并把 SayAll 的语音触发键选为右 Command；微信输入法仍按教程配置 Fn。语音测试中按遥控器触发语音，SayAll 能收到完整音频会话，但输入框没有第三方工具提交的文字，流程停在语音测试页。

1.9.19 (172) 现场诊断的关键事实：

```text
voice_tool=weixin
voice_key_mode=right_command
voice_started=true
voice_samples_received=true
voice_ended=true
voice_editor_mounted=true
voice_window_key_at_start=true
voice_first_responder_at_start=true
voice_first_responder_at_end=true
voice_focus_lost=false
transcription_appeared=false
voice_terminal_result=external_tool_no_commit
voice_diagnostic_boundary=external_tool_internal_state_unavailable
```

## 日志结论与根因

- SayAll 可观察到的权限、控制连接、音频设备、语音开始/采样/停止和输入框焦点均已满足。
- `external_tool_no_commit` 只表示第三方工具没有把文字提交到输入框；按照跨应用数据边界，SayAll 无法读取其私有配置或内部识别状态。
- 代码中 Onboarding 语音工具页允许选择 Fn、左 Command、右 Command，但微信/豆包教程固定要求 Fn。用户可以在 UI 中选择一个与教程不一致的按键，且进入语音测试后没有持续、强约束地纠正这个不一致。
- 根因已由用户现场确认：Onboarding 的按键策略过于宽松，导致 SayAll 触发键与第三方输入法按键配置不一致。

## 修复方案

1. Onboarding 全流程统一使用 Fn/地球键；不再显示 Command 选择器。
2. 进入或重跑 Onboarding 时，把旧的 Command 状态切换为 Fn；完成后不静默恢复旧 Command。
   - 如果确实发生了 Command → Fn 迁移，欢迎页和语音工具页显示不可忽略的提示，明确列出原按键、当前 Fn/地球键和完成后可改回的位置；原本就是 Fn 的用户不显示该提示。
3. 豆包、微信、Typeless 和“其他语音工具”的首次配置文案统一说明 Fn；其他工具仍必须自行开启语音输入并选择正确麦克风。
4. 主设置页继续支持 Fn、左 Command、右 Command。用户主动切换 Command 时，页面明确要求第三方工具同步配置、SayAll 无法自动验证，并将状态视为待用户实际验证。
5. 诊断摘要记录 `onboarding_voice_key_policy=fn_only`、实际 `voice_key_mode`、版本/系统完整身份和按键策略不一致状态；不记录输入内容或第三方私有状态。

## 验证计划

- 流程自动化：Fn-only 门禁、旧 Command 迁移、重跑不恢复旧模式、主设置页 Command 仍可选。
- 日志自动化：诊断 schema、版本/系统字段、按键策略字段、单次语音终态及隐私红线。
- UI：实体遥控器、iPhone、网页版三条分支，浅色/深色完整 Onboarding 截图逐张检查；额外检查设置页按键模式提醒。
- 迁移提示 UI：使用左 Command、右 Command 和 Fn 三种初始状态分别渲染欢迎页与语音工具页，确认仅前两者显示准确的来源按键和后续设置说明。
- 真实环境边界：需要 RC003、微信/豆包/Typeless 和其他语音工具各自按 Fn 完成真实文字上屏；截图、单元测试和模拟硬件不能替代第三方工具验收。

## 验证结果

- 流程自动化：`swift test --filter OnboardingFlowTests` 通过（39 项）；覆盖 Fn-only 门禁、旧 Command 迁移提示、Fn 不显示迁移提示、重跑不恢复旧模式、三种控制方式门禁、返回导航和完成后设置保留。
- 设置页回归：`swift test --filter SettingsPageRegressionTests` 通过（27 项）；Command 仍可选，并显示未验证和第三方工具配置提醒。
- 本地化：`swift test --filter LocalizationTests` 通过（6 项）。
- 全量 Swift 测试：`swift test` 通过 428 项/37 个 suite。
- 自检：`SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh` 通过，44 项通过；仅有既存 macOS 14 `onChange` 弃用警告。
- 截图：使用生产 `OnboardingView` 离屏入口生成实体遥控器 18 张、iPhone 20 张、网页 20 张，共 58 张（均为有效 PNG，2040×1608）；三条分支浅色/深色已逐张检查，无裁切、黑白分栏或导航缺失。产物目录：`.codex-screenshots/onboarding-fn-policy-20260831/`。
- 设置页截图：中文/英文、浅色/深色各生成 7 个侧边栏页面（800×650 窗口，PNG backing scale 为 2，文件像素 1600×1300），并检查按键映射页浅深色布局；产物目录：`.codex-screenshots/settings-fn-policy-20260831/`。
- 迁移提示截图：使用生产 `OnboardingView` 离屏入口分别注入左 Command、右 Command 和默认 Fn，实体遥控器分支浅色/深色各 9 张，共 54 张；已逐张检查欢迎页和语音工具页的来源按键文案、浅深色对比度、无裁切，以及默认 Fn 不显示迁移提示。产物目录：`.codex-screenshots/onboarding-voice-key-migration-20260831/`。
- Release 构建：`./scripts/build-app.sh` 通过，产物为 `dist/SayAll.app`；当前是本地 ad-hoc 签名，不能替代 Developer ID、公证和 staple 验收。
- 真实设备边界：尚未在本分支执行 RC003、iPhone Nearby、网页版 WSS、MiRemoteV/BlackHole 真实设备，以及豆包、微信输入法、Typeless 和其他语音工具的真实文字上屏验收；这些仍是 CI 后的现场门禁。
