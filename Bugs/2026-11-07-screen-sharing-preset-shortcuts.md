# 屏幕共享中内置组合键丢失修饰键

## 状态与范围

- 基线：`91f27056f7eda1751411ca5b1dfaa1827ef01b28`。
- 状态：主线源码候选；用户已确认 1.9.21 本地测试变体的遥控器与屏幕共享可用，主线 App 尚未做同等现场验收。
- 范围：内置 Command/Shift 组合键与已有自定义快捷键共用完整事务。不改语音键、AppSwitcherSession、配置格式、权限策略或音频行为；不增加延时。

## 错误证据与边界

用户使用两台 Mac 的屏幕共享时，实体键盘 Command+V 正常；鼠标映射和 SayAll 1.9.21 遥控器映射只输入 v，实体按住 Command 再触发鼠标键可以粘贴。用户在独立的 Panda Mac Tools 中确认完整修饰键事件加 HID 投递方案可用。这只能支持事件协议方向，不代表 SayAll 已经现场通过。

未取得 SayAll 原始脱敏日志或真实设备采集。1.9.21 的内置动作和自定义组合均只有主键事件与 flags；当前主线自定义组合已使用 ShortcutEventSequence，但内置组合仍走 postKey。以不向系统投递的回归测试验证当前主线的这个差异，不能据此证明屏幕共享内部读取修饰键状态的具体机制。

## 根因实验

修改产品代码前，将既有 13 个内置组合测试改为检查完整事件事务，并增加粘贴的实体键保留、提交失败清理/恢复和权限拒绝用例。通过注入的事件提交器收集事件，旧 keyPoster 只报告失败，不向 WindowServer 发送任何按键。

定向命令：

```sh
SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'builtInPaste|fixedCompoundShortcutsPostExpectedKeyCodesAndModifiers'
```

修复前：4 项定向测试中 3 项失败，共 92 个 issue，旧 keyPoster 被调用而完整事件提交器未收到事件。修复后：定向相关套件 191 项测试通过。权限拒绝用例修复前后均通过。

## 最小修复

内置 Command/Shift 组合复用 ShortcutEventSequence.send，使用同一物理修饰键快照、左右设备位、修饰键按下与逆序释放、失败清理和 HID 投递入口。返回实际事务提交结果，日志明确 user_visible_result=unknown。自定义组合使用相同的局部入口和调用者日志输出。

裸键、系统媒体键、独立修饰键、Fn 桌面动作和持续按住 Command 的 AppSwitcherSession 保持各自既有路径；不把长按模式替换为一次性组合。

## 验证

2026-11-07 本地公开依赖模式验证：

- 相关回归：191 tests / 2 suites 通过。
- 完整公开测试（排除 BuildSigningTests）：1225 项中仅输入源相关的 resolvesCommaOnMainAfterReturningFromTheTapThread 失败，当前中文输入源得到全角逗号，测试期望半角。将 KeyboardInjector 恢复为精确主线后，单独运行同一用例仍失败，已确认是现有基线问题；未修改该测试或用户输入源。
- 排除上述现有输入源用例与 BuildSigningTests 后：1224 tests / 87 suites 通过，包含宏快捷键提交回归。
- SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh：48 passed / 0 failed。
- Apple Silicon Release（arm64-apple-macosx14.0）：构建通过；存在既有弃用及并发警告。
- git diff --check、verify-repository-governance.sh origin/main 通过。
- Intel 构建与本主线候选 App 的遥控器实机/屏幕共享尚未完成，不作为通过项。

创建上传候选前再次 fetch，origin/main 仍为本文基线；检查 Open PR #409、#478、#403 的描述、文件与相关差异，分别涉及连发、增加预设、应用切换与捕获，不覆盖现有 13 个内置组合的生命周期迁移；历史 #531 是自定义修饰键侧别修复，已在主线，本次复用其事务而不重复实现。此前按屏幕共享关键词检索无同范围 PR。

2026-11-07，用户在 1.9.21-local-test (175) 中实测后回复“可用”。该变体以公开兼容层替代缺失的私有手机组件，仅供实体遥控器测试，并使用完整修饰键按下/主键/释放方案；源码提交 612ea803fc5a0011a95666fcf97ab6c0badc5f7a，仅保存在本地。此结果支持发送方案在用户屏幕共享环境下可行，不代表当前主线候选 App 已完成同等现场验收；未收集完整硬件/系统矩阵或逐项手册记录。旧版兼容层和测试包改动不进入本主线修复。用户随后授权推送主线修复并提交 PR。

按 [快捷键生命周期手册](../Testing/CustomShortcutLifecycle.md) 的屏幕共享用例做现场验收；自动化结果只证明发送协议和清理，不替代遥控器或目标 App 的最终响应。
