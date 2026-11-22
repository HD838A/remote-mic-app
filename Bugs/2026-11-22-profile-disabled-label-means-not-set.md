# 键位方案里的 disable 被显示成「本方案禁用」，实际含义是「未设置」

- 时间：2026-11-22
- 影响范围：按键页的方案作用域卡片、动作编辑区和悬停帮助
- 简单描述：方案内的 `disabled` 绑定表示“本方案没有为该手势设置动作”，不是把按键或手势禁用。界面把它显示成「本方案禁用」，用户会理解成该按键在本方案中被主动禁用。

## 证据

- 生产 `SettingsView` 离屏截图 `Screenshots/profile-editability-inheritance/manifest.json` 中，方案卡片和编辑区把该状态显示为「本方案禁用」；同一批截图里基础映射显式停用显示「禁用」、从未设置显示「无动作」。
- 代码路径：`mappingActionSummary`、`explicitProfileBindingLabel` 和 `mappingActionDetail` 对 `configured.action == .disabled` 使用 `button_mapping.action.profile_disabled`。
- 本地化值：中文「本方案禁用」，英文 `Disabled here`。
- 方案数据层把该状态存为显式 `disabled` 绑定；执行时该手势不执行动作，但语义是“本方案未设置动作”，不是禁用整颗按键。

## 根因

PR #1063 为区分“继承默认”“本方案覆盖”和“本方案未设置”，把方案内的 `disabled` 绑定命名为「本方案禁用」。命名只强调了动作不执行，忽略了它在方案覆盖层的含义：该手势没有设置动作。

## 修复

- 方案卡片、动作编辑区和悬停帮助统一改显示「未设置」/`Not set`，短文案能放进窄格子。
- 基础映射文案保持原样：从未设置继续显示「无动作」，显式停用继续显示「禁用」。
- 本地化键从 `profile_disabled` 改名为 `profile_not_set`，避免后续再把该状态理解成禁用。

## 验证

- `scripts/verify-localizations.sh` 与 `git diff --check` 通过。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain` 通过。
- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'SettingsPageRegressionTests|ButtonBindingConfigurationTests'` 通过，108 项测试；新增 `profileDisabledBindingReadsAsNotSet` 静态回归，锁定新文案和基础映射不受影响。
- 使用私有 2.14.0 构件 `swift build --disable-keychain` 通过；生产 `SettingsView` 离屏入口渲染中文/英文、浅色/深色 `1020 × 772`（PNG `2040 × 1544`）的方案总览和编辑区，卡片和编辑区均显示「未设置」/`Not set`，没有截断。截图字节保存在仓库外 `~/Develop/ReleaseArtifacts/profile-not-set-label-20261122/attachments/`，只证明静态文案，不证明真实会员或遥控器动作。

## 未覆盖边界

- 不改变方案内 `disabled` 的存储格式、执行语义或“停用此动作”开关的行为。
- 旧方案数据里已写入的展示名不受影响；本轮只改宿主按键页的显示。
- 真实会员、旧安装包和实体遥控器动作仍需现场验收。
