# 键位方案页按住标签继承缺失与动作错位

## 现象与证据

用户在键位方案页发现两类现象：

1. 基础映射已经配置按住效果，方案没有覆盖按住时，方案卡片的同按键没有“按住”标签。
2. 方案显式覆盖按住时，标签显示的重复动作来自按键页当前正在编辑的方案，而不是方案页正在查看的方案。例如方案把“确定”单击设为“↓”、按住设为“重复单击”，卡片同时显示“单击 ↓”和“按住：重复 ↓”；旧实现可能显示基础映射的“重复 回车”。

现场证据来自用户报告和方案页截图；修复后的截图显示“确定”卡片同时显示“单击 ↓”和“按住：重复 ↓”。没有可用的旧版本日志，因此根因通过代码路径和新增回归测试确认，其中测试在旧实现下无法通过新接口取得按方案解析的结果。

## 根因

- 私有组件 `RemoteMicButtonProfilesView.bindingCard` 只读取 `profile.holdModes?[button.rawValue]`。方案没有存储按住模式时，该值为 `nil`，即使基础映射有按住效果也不显示标签。
- 公开宿主 `SettingsView.mappingHoldSummary(for:profileID:)` 用传入的 `profileID` 解析按住模式，却调用 `mappingHoldActionSummary(for:trigger:)`，后者内部读取 `editingMappingProfileID`。方案页浏览的方案与按键页编辑的方案可以是两个不同方案，因此动作摘要会落到错误方案。
- 方案页和按键页各自拼接按住文案，缺少一个只按目标方案解析模式和动作的纯逻辑入口，导致同类回归无法被直接测试。

## 修复

- 新增 `ProfileHoldPresentation` / `ProfileHoldPresentationResolver`：显式模式优先；继承时回落基础模式；基础模式为单次或不支持时不显示标签；动作始终通过传入的 `profileID` 解析，不读取按键页编辑状态。
- `SettingsView` 新增 `profileHoldSummary` 和 `profileHoldMode`，作为方案页唯一的模式和文案入口；`mappingHoldActionSummary` 增加显式 `profileID` 参数，旧调用点仍使用当前编辑方案。
- 私有组件新增 `RemoteMicHoldTagPresentation.resolvedMode(profileStored:hostResolved:)` 和 `holdModeProvider`。新宿主传入解析后的有效模式；旧宿主不传时回落到方案存储值。
- 私有 `SayAllButtonProfilesFeature.buttonProfilesView` 透传 `holdModeProvider`。公开宿主通过 `SAYALL_BUTTON_PROFILE_RESOLVED_HOLD` 编译条件调用新参数，私有二进制版本未更新时不破坏构建。

## 验证

| 范围 | 命令或证据 | 结果 |
| --- | --- | --- |
| 公开宿主纯逻辑与回归 | `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build/public --filter 'ProfileHoldPresentationTests\|profileHoldSummaryUsesTheViewedProfileAction\|SettingsPageRegressionTests\|ButtonBindingConfigurationTests'` | 115 项 / 3 个套件通过 |
| 公开宿主 + 私有 2.15.1 二进制 | 同一 scratch 的定向测试 `ProfileHoldPresentationTests\|profileHoldSummaryUsesTheViewedProfileAction\|profileHoldSummary` | 7 项 / 2 个套件通过 |
| 私有组件 | `packages/macos-button-profiles` 下 `swift test --disable-keychain` | 169 项 / 16 个套件通过 |
| 私有源码集成构建 | `SAYALL_ENABLE_PRIVATE_SWIFTPM=1 SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH=<symlink> swift build --disable-keychain --scratch-path .build/private-source -v` | 构建通过，`RemoteMic` 编译参数包含 `SAYALL_BUTTON_PROFILE_RESOLVED_HOLD` |
| 方案页 UI | 真实设置窗口，方案“演示用的长名称键位方案与按…”；基础映射“确定”单击为回车，方案“确定”单击为 ↓、按住为重复单击 | 卡片显示“按住：重复 ↓”，与单击“↓”一致 |

## 未覆盖与后续

- 私有 2.15.1 二进制宿主不传 `holdModeProvider`，因此基础按住继承标签要等私有组件 Tag 更新并由公开仓库 pin 后才可见；当前公开 PR 只保证动作摘要修复和可测试入口。
- 截图只证明静态 UI；未接真实遥控器验证按住动作执行，也未做真实音频/语音键回归，因为本次变更只影响标签解析和文案。
- 私有标签、跨方案切换和真实按住执行需要在私有组件 pin 后按 `Testing/UnifiedButtonConfiguration.md` 的方案页新增用例复查。
