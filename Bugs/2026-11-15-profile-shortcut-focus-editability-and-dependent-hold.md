# 2026-11-15 键位方案内的快捷键/focus 绑定只读，动作变化后旧按住设置残留

## 现象

- 会员选择一个非默认键位方案后，方案里已有的快捷键绑定（例如主页键显示 `⌘⇧H`）仍显示「此配置为只读」，动作选择器和停用开关不可用。
- 同一按键的「按住时」面板也显示「此配置为只读」，即使方案组件支持写入按住模式。
- 已设置「按住时 重复单击动作」的按键，把单击动作改成其他动作后，旧按住设置仍然生效；界面没有提示需要重新选择，用户只能再进一次按住面板才发现。
- 在方案内，继承默认方案的动作和方案显式禁用都显示成同一个「不执行」，用户无法判断当前动作来自默认方案还是本方案。
- 基础映射中从未设置的动作显示「未设置」，有人误以为和显式禁用不同。

## 证据

用户现场截图：

- 方案内的主页键绑定显示 `⌘⇧H`，面板同时显示「此配置为只读」。
- 同一按键的按住面板整块只读。
- 按键在默认方案下可以正常修改。

代码与数据证据：

- `Sources/RemoteMic/MacroFeatureIntegration.swift` 的 `displayProfileBinding` 对 `.shortcut`、`.focus` 直接写入
  `configured = nil`、`editable = false`；宿主只把这两类引用当作展示文本。
- `Sources/RemoteMic/SettingsView.swift` 的 `canWriteMappingHold` 要求该按键三个手势都可写，任一快捷键/focus
  绑定被判定只读时，整个按住面板一起锁住。
- `mappingActionSummary` 只要处于方案编辑状态就返回「不执行」，没有区分继承默认、方案覆盖和方案禁用。
- `reconcileMappingHoldMode` 只在动作保存后清理已经不可执行的按住值，不会在动作变化时主动清除依赖该动作的按住设置；
  `clearMappingOverride` 也没有触发按住清理。
- 现场方案数据中的快捷键引用和按住模式都完整，组件可以读取；问题只在宿主的可编辑判定和显示层。

## 根因

1. **快捷键/focus 引用被当成不可编辑的外部展示**：它们实际是组件的一等绑定，可以解码成宿主已有的
   `customShortcut` / `focusInput` 动作模型，但宿主没有解码，直接把整键判成只读。
2. **按住可用性错误地依赖所有动作可写**：快捷键/focus 只读时，按住面板被连带锁死；用户既不能改按住模式，
   也不能清除覆盖。
3. **动作变化与按住设置没有关联**：单击或长按动作变化后，依赖该动作的按住模式（重复单击、按住、重复长按、
   长按后按住）仍保留，形成不可见的旧行为。
4. **来源信息丢失**：方案编辑状态把所有禁用值压成同一个文案，继承和覆盖无法区分。

## 修复

- 方案的 `.shortcut` 引用通过组件快捷键库解码为 `customShortcut`；`.focus` 解码为 `focusInput`。只有引用无法
  解析时才保持不可用；解析成功的绑定按普通动作可编辑，可改选动作或恢复继承默认。
- 动作摘要按来源显示：继承默认方案显示「默认 · <动作>」，方案覆盖显示「本方案 · <动作>」，方案显式禁用
  显示「本方案禁用」；基础映射未设置显示「无动作」，显式禁用显示「禁用」。继承行增加链接图标。
- 单击或长按动作真正变化且保存成功后，清除依赖该手势的按住模式；如果旧按住模式已经因为新动作产生冲突，
  也一并清除。清除写回当前编辑作用域（基础或方案）的显式 `once`，避免方案继承的旧按住重新出现。
- 清除成功显示「动作已改变，按住设置已清除」；清除失败显示「动作已保存，但按住设置清除失败」并提供重试。
  失败提示在成功回执消失后继续保留，直到重试或下一次动作写入。
- 方案内恢复继承默认也会触发同一套按住清理。
- 首次编辑的默认按住行为保留，但不再把继承自基础方案的显式 `once` 当成未设置并重新写入重复模式。
- 方案内任一动作不可写时，仍允许把按住清除到 `once`；不可写的动作不会被静默改写。
- 动作写入和按住清理使用同一个 `operation_id` 关联，日志记录触发手势、旧按住模式和最终结果。

## 验证

- `swift build --disable-keychain`：私有源码组合动作 + 按键方案包编译通过。
- 定向测试：`ButtonBindingConfigurationTests` 与 `RemoteButtonInteractionTests` 共 61 项通过；新增动作变化清除策略
  和保存回执生命周期用例。
- 公开模式：`SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --scratch-path .build/public`，
  1447 项测试、104 个套件通过。
- 私有方向键源码：`SAYALL_ENABLE_PRIVATE_SWIFTPM=1 SAYALL_ENABLE_BUTTON_PROFILES=1` 指向私有 PR #460
  的干净 checkout，跳过与本修复无关的 `releaseControlPlaneFixtureHasExecutableRegressionCoverage` 后
  1512 项测试、113 个套件通过。该发布控制面 fixture 在公开模式通过；私有模式下受本机环境限制失败。
- 生产界面：由生产 `SettingsView` 的离屏入口生成中文浅色 `1020 × 772`（PNG `2040 × 1544`）截图，覆盖方案总览、
  快捷键编辑、focus 编辑、继承默认行、可写按住面板、清除成功和清除失败重试。方案访问由截图 fixture 授权，
  不代表真实会员状态；图片字节保存在仓库外证据目录，仅以 PR 附件和文本索引归档。索引见
  `Screenshots/profile-editability-inheritance/manifest.json`。
- `scripts/verify-localizations.sh`、`scripts/verify-repository-governance.sh`、
  `scripts/check-repository-boundaries.sh` 与 `git diff --check` 通过。

## 未覆盖边界

- 本轮不验证真实会员到期、付费墙、旧安装包升级和实体遥控器最终动作。
- 私有 2.12.0 构件是否包含最新的方向键按住能力由独立私有版本决定；本轮只验证宿主侧编辑与清理逻辑。
- 截图只证明静态界面和状态文案，不证明目标 App 收到快捷键或 focus 动作。
