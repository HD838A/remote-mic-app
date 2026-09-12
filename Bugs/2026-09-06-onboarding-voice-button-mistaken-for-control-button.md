# Onboarding 语音键被误当作普通控制键

- 时间：2026-09-06
- 现场版本：无线麦SayAll.app `1.9.19 (172)`
- 修复基线：最新 `origin/main`，候选版本 `1.9.21 (174)`
- 影响范围：首次使用向导的实体遥控器连接与普通按键检查页

## 复现

1. 进入实体遥控器 Onboarding 的遥控器连接页。
2. 遥控器已经建立 BLE 语音连接，页面仍要求收到一个普通控制键。
3. 用户把麦克风/语音键当作页面要求的按键，短按两次。
4. 页面继续显示 `remote.button_not_ready`，无法进入下一步，也没有说明刚才收到的是语音键。

正常边界：只有生产 HID 链路收到普通控制键后才能继续；语音键不能代替该门槛，但页面必须解释用户刚才的操作为何无效。

## 日志证据

用户现场日志在进入 `remote` 后记录了两次极短的 ATVV 语音会话：

```text
ONBOARDING STEP entered=remote
ATVV STREAM START
ATVV STREAM STOP duration_ms=146
ATVV STREAM START
ATVV STREAM STOP duration_ms=180
ONBOARDING DIAGNOSTICS copied failure=remote.button_not_ready
```

同一失败进程没有 HID 普通按键报告；历史进程中同一类遥控器曾正常产生 OK 键报告。权限、BLE 和音频准备均成功，因此不是“无法连接”，而是连接后没有收到 Onboarding 所要求的普通控制键。

## 根因

遥控器页等待阶段把生产 `hidStatus`（通常为“按键功能已连接”）作为按键卡的主要详情。真正的操作说明“语音键以外的任意普通按键都可以”只有在已经收到普通按键之后才显示。

因此用户在最需要指导时看不到应该按什么，也看不到不能按语音键。生产链路实际上收到了语音键并启动了语音会话，但 Onboarding 没有把这个已确认事实映射为页面反馈和诊断字段，最终只输出笼统的 `remote.button_not_ready`。

## 修复

1. 等待普通按键时直接要求短按圆盘中间确定键或方向键，并明确排除麦克风/语音键。
2. 复用生产 `isStreaming` 与 `activeVoiceSource`，在实体遥控器页收到当前来源的语音开始事件时立即显示橙色“刚才按的是语音键”纠正卡。
3. 普通控制键仍只由生产 HID 事件满足；普通键到达后清除纠正状态并沿用原门槛。
4. 诊断新增语音键触发次数、普通控制键观察次数、最后输入类型和是否曾检测到误按，日志分别记录 `observed=voice` 与 `observed=control`。
5. 不修改 BLE、HID、ATVV、音频或语音键按下/释放实时语义，不读取或记录设备身份、用户内容或第三方 App 私有状态。

## 验证

- 失败优先测试：修复前 `OnboardingFlowTests` 因缺少远程输入诊断类型而失败。
- 定向自动化：`xcrun swift test --disable-keychain --filter OnboardingFlowTests`，49 项通过；`xcrun swift test --disable-keychain --filter LocalizationTests`，6 项通过。
- 完整 Swift 测试：`xcrun swift test --disable-keychain`，459 项、39 个 suite 全部通过。
- 项目自检：`SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`，44 项通过、0 项失败。
- Release 构建：`xcrun swift build --disable-keychain -c release` 通过；仅保留仓库既有的 API 弃用警告。
- UI 截图：使用生产 `OnboardingView` 隐藏离屏入口生成并逐张检查实体遥控器 18 张、iPhone 20 张、网页版 20 张，共 58 张完整流程浅色/深色截图；另检查实体遥控器误按语音键状态浅色/深色各 1 张。窗口 chrome、标题、导航、状态卡、右栏、裁切、对比度和中文字号均通过，截图保存在未提交的 `.codex-screenshots/onboarding-control-button-guidance-20260906/`。
- 真机边界：自动化和截图不能替代真实 RC003 的 ATVV/HID 事件；需在候选包上按本文件复现步骤完成最终真机验收。
