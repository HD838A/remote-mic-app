# 2026-11-14 键位方案内组合动作与“按住”被误判只读

## 现象

- 会员选择非默认键位方案后，给某个按键配置组合动作；该按键随即显示“此配置为只读”，动作选择器和停用开关不再可写。
- 同一方案的“按住时”面板显示“此配置为只读”，或者选择按住模式后显示“动作已保存，按住未保存”。
- 相同按键在默认方案（基础映射）下可以正常配置。
- 旧私有构件 2.9.0 和新版自动保存构件都能看到该问题；方案数据本身没有损坏。

## 证据

现场截图：

- “右键 · 长按”动作已保存，但“按住未保存”并显示重试。
- “主页键 · 长按”已选组合动作“凡人修仙传 test”，动作区显示“此配置为只读”，下方仍有“清除覆盖”。
- 另一个方案的“右键 · 按住时”整块显示“此配置为只读”。

代码证据：

- `Sources/RemoteMic/MacroFeatureIntegration.swift` 的 `displayProfileBinding` 在 `.macro` 分支用
  `savedMacroVersion(id:) == reference.version` 判断可编辑。组合动作被编辑后版本会递增，方案里钉住的旧版本因此永久只读。
- `Sources/RemoteMic/SettingsView.swift` 的 `canWriteMappingHold` 要求所有手势都可写；任一长按组合动作因版本过期只读时，整个“按住时”面板也会被判只读。
- 发布版私有键位方案组件（2.11.0）只接受 `once`、`repeatSingle`、`repeatLong` 三种 hold mode；宿主却向方案用户提供 `singleHold` / `longHold`（方向键按住）。用户选择这两种模式时组件返回 `write_denied`，宿主显示“按住未保存”。
- 本次已在私有 PR #460扩展 hold mode 白名单，并增加 `supportsDirectionalHoldModes` 能力标记；尚未发布 Private Tag。
- 私有组件读取到不支持的旧 hold mode 时返回 `.unavailable`；原实现又把该状态视为整块只读，导致无法用受支持的模式覆盖恢复。

## 根因

1. **组合动作版本比较过严**：宏 ID 仍存在、执行路径也会回退到当前版本，但显示层把旧版本固定引用当成不可编辑。
2. **方案“按住”能力声明不完整**：宿主按基础映射的能力展示四种按住行为，没有区分已发布方案组件只能持久化重复模式；本次已在私有源码补齐方向键按住能力，并用宿主探测标记渐进启用。
3. **只读范围过大**：某个按住值不可用时锁住整个按住面板，而不是允许用户选择组件支持的模式或清除覆盖。

## 修复

- 方案内的组合动作只要宏 ID 仍存在就可编辑；打开选择器并保存时才写入当前版本，显示和复制继续保留原钉住版本。
- 新增宿主能力集合 `supportedProfileHoldModes`：私有源码提供 `supportsDirectionalHoldModes` 时方案内提供 `once`、`repeatSingle`、`repeatLong`、`singleHold`、`longHold`；固定 2.11.0 等旧构件仍只提供重复模式。
- 私有源码把 `singleHold` / `longHold` 加入 feature、controller、创建、导入和旧数据清理的统一白名单，并新增私有测试。
- `writeProfileHoldMode` 在调用私有组件前拒绝不支持的 hold mode，避免把组件失败伪装成存储失败。
- 从基础创建方案时过滤组件不能持久化的 hold mode，避免整个方案创建或复制被拒绝。
- 旧构件复制源方案时也跳过不支持的 hold mode。
- `canWriteMappingHold` 不再因单个不可用 hold 值锁住整个面板；用户可用受支持模式覆盖恢复。
- 旧构件下按住面板说明“方案只保存重复执行模式，方向键按住请在默认方案设置”；具备方向键能力时不显示该限制。
- 按住写入日志补充 `mode` 和确定性的完成结果，便于后续现场定位。
- 把“当前配置冲突”改为具体原因和解决路径，例如点名长按动作，并提示清除长按动作或改选重复执行长按；不再只显示泛化冲突。

## 验证

- 公开模式：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build/public --skip releaseControlPlaneFixtureHasExecutableRegressionCoverage`，1443 项测试、104 个套件通过。
- 私有 2.9.0：`SAYALL_ENABLE_PRIVATE_SWIFTPM=1 SAYALL_ENABLE_BUTTON_PROFILES=1` 使用 Tag `2.9.0` checkout，1509 项测试、113 个套件通过。
- 私有主线源码：同一命令使用含自动保存接口的私有 checkout，1509 项测试、113 个套件通过。
- 私有 2.11.0 固定构件：方案集成用例覆盖不支持的 hold mode 被过滤、`singleHold` / `longHold` 写入被拒绝、`repeatLong` 写入成功；过期宏版本可编辑的源码回归。
- 私有方向键按住源码：`profilePersistsDirectionalHoldModes` 与宿主依赖该源码的集成用例通过；`singleHold` / `longHold` 可创建、读取、重载和写入。私有包 158 项测试、15 个套件通过。
- `scripts/verify-repository-governance.sh`、`scripts/check-repository-boundaries.sh`、`scripts/verify-localizations.sh`、`git diff --check` 通过。

## 未覆盖边界

- 本轮未重新执行真实会员到期、续费、旧安装包升级和实体遥控器验收。
- 本次未发布新的 Private Tag，固定 2.11.0 的分发构建仍只显示重复模式；方向键按住支持仅在私有源码本地构建生效，待后续发布流程升级清单。
- 截图和单元测试只证明宿主状态与持久化映射，不证明目标 App 最终响应。
