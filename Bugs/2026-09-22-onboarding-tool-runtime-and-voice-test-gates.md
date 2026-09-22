# Onboarding 输入工具未运行、配对状态残留与语音测试页裁切

- 时间：2026-09-22
- 状态：候选修复完成，等待 Vokie、Typeless 与实体遥控器真实验收
- 影响范围：Onboarding 输入工具选择、配对计划、语音测试页

## 观察

现场反馈包含四类现象：选择 Vokie 后 App 实际没有运行；Typeless 可能有同样问题；语音测试输入框已有文字但“继续”仍不可用；切换推荐/学习或手势选项后按钮状态不刷新。语音测试页的红色“当前/应为”文案和底部状态提示也被裁切。

同一轮现场日志还显示，用户在工具页反复切换豆包、微信、Vokie、Typeless 和其他工具时，单次选择后短时间内会产生多次 `ONBOARDING INPUT SOURCE ... result=selected`。这与选择动作触发输入源切换、系统前台变化和输入源排序重算相符。

## 复现与代码证据

1. Vokie 的原实现只用公开 URL scheme 判断“已安装”，Typeless 只用公开 bundle identifier 判断“已安装”，两者都没有区分 App 是否正在运行。
2. 切换 Onboarding 的 Binding 或手势时，原实现只清空 staged binding；已经存在的试用快照和当前 `voiceKeyMode` 可能继续保留旧配置，导致配对摘要与无线麦实际状态不一致，语音文字即使出现也无法满足继续门禁。
3. 语音测试配置卡把长状态值放在单行 `HStack` 中，有限宽度下会截断；左栏和右栏没有对超高错误卡/状态卡提供垂直溢出保护。

## 修复

- 通过公开的应用 URL、Bundle 和 `NSWorkspace.runningApplications` 增加 Vokie/Typeless 运行状态；进入语音测试页时未运行或状态未知会触发后台启动。自动拉起失败、状态未知或目标仍未运行时阻止完成并提供“重新打开”；目标运行后仍需通过真实语音测试。没有读取第三方 App 私有文件、数据库或协议。
- 统一在切换输入工具、Binding 来源、手势和控制来源时恢复旧试用配置，再重新生成并应用当前 staged 配对计划，避免旧 Fn hold/tap 状态残留。
- 将配置状态改为可换行的纵向状态行，错误和底部状态文案使用完整高度；左右内容增加垂直滚动保护，避免恢复卡和实时检查在小窗口中被裁切。
- 工具卡片改为固定顺序；选择豆包/微信时只观察当前输入源，只有用户明确点击切换按钮才调用公开输入源 API，避免 Radio 选择造成页面跳动和系统确认/设置界面。
- 进入 Typeless/Vokie 语音测试页时通过公开 Bundle ID/URL Scheme 后台启动目标 App，不激活目标窗口；启动结果异步刷新运行状态，失败时仍保留手动打开入口。

## 验证

- `swift test --disable-keychain --filter OnboardingFlowTests`：51 项通过。
- `swift test --disable-keychain`：673 项、53 个测试套件通过。
- `git diff --check`：通过。
- 生产 `OnboardingView` 离屏截图已更新到 `Screenshots/design-drafts/onboarding-tool-binding-fixes/vokie-light-3/`、`vokie-dark-2/`，并额外生成豆包工具页浅/深色截图；每张 PNG 均为 2040×1608，已查看工具卡固定顺序、配置文案和底部按钮未被裁切。

## 验收边界

自动化和离屏截图不能证明真实 Vokie/Typeless 进程状态、MiRemoteV 2ch 音频、遥控器按键或第三方文字上屏；这些仍需在本地包中使用真实 App、虚拟音频设备和遥控器验收。
