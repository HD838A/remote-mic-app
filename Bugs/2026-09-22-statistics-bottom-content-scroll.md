# 个人中心统计页底部内容滚动 Bug

环境：macOS 27.0（Build 26A428），Xcode 26.4，分支 `codex/sidebar-profile-login-20260921`，当前 HEAD `bbfc0a3f`。

## Observations

- 个人中心对应公开宿主 `Sources/RemoteMic/SettingsView.swift` 的 `statisticsPage`，不是私有会员中心。
- 现有 1020×772 统计页截图中，右侧“单次语音时长排行榜”面板只显示上沿，底部内容延伸到窗口可视区域之外。
- 800×650 窄宽截图也显示该面板从底部开始出现，说明页面内容确实超过当前 viewport；截图渲染本身未报告错误。
- 用户反馈为：个人中心底部内容无法完整显示，滚动后可以看见，但滚动边界/方向反馈不清楚，用户不知道底部还有什么内容。
- `settingsPage` 使用纵向 `ScrollView`，且显式关闭滚动指示器：`ScrollView(.vertical, showsIndicators: false)`。
- `statisticsPage` 使用 `GeometryReader` 计算左右栏宽度，并给该区域设置 `.frame(minHeight: 648)`；右栏内部仍有日历和语音时长排行榜两个纵向面板。
- `~/Library/Logs/RemoteMic/runtime.log` 未发现统计页布局、滚动或底部内容失败事件；这只能说明当前日志没有该诊断链路，不能替代 UI 复现。

## Hypotheses

### H1：统计区域固定的最小高度导致子内容超出父布局边界（ROOT HYPOTHESIS）

- Supports：`GeometryReader` 被 `.frame(minHeight: 648)` 约束，而左侧排行榜和右侧两个面板的实际高度可能超过 648；截图显示底部面板被截在 viewport 下方。
- Conflicts：当前截图仍能在页面下方看到语音排行榜上沿，说明外层滚动至少能识别一部分内容。
- Test：将实验分支中的 `minHeight` 临时提高到足以容纳现有内容，重新渲染并检查底部内容是否完整进入可滚动内容范围。

### H2：`settingsPage` 的外层 `ScrollView` 没有明确填满右侧内容区域，导致 viewport/滚动范围由内容理想尺寸决定

- Supports：滚动容器位于 `VStack` 中，没有显式 `.frame(maxHeight: .infinity)`；窗口尺寸变化时可能出现不同的提议高度。
- Conflicts：其他设置页共用该容器，当前反馈集中在统计页的复杂布局。
- Test：仅给实验中的外层 `ScrollView` 增加最大高度填充约束，观察统计页和其他页面的渲染是否改善且无几何变化异常。

### H3：嵌套 `GeometryReader` 在外层纵向 `ScrollView` 中错误传播高度提议

- Supports：`GeometryReader` 在未确定高度的纵向滚动内容中使用，内部 `HStack` 又包含多个纵向面板，属于容易产生理想尺寸/实际尺寸不一致的布局组合。
- Conflicts：宽度计算本身正常，当前截图中左右栏宽度和上部内容均可见。
- Test：仅把统计区域的 `GeometryReader` 临时替换为固定宽度计算所需的非嵌套布局实验，比较底部内容可达性。

### H4：隐藏滚动指示器造成“没有底部内容”的可见反馈缺失

- Supports：`showsIndicators: false` 使用户看不到当前位置和剩余滚动范围，符合“不知道底部还有什么内容”。
- Conflicts：它不能单独解释底部内容无法完整滚到可视区域，最多解释发现性问题。
- Test：仅打开纵向滚动指示器，检查是否改善用户对剩余内容的判断；若内容仍被裁剪，则 H4 不是根因。

## Experiments

### E0：基线检查

- 方法：查看现有 `SettingsScreenshotRenderer` 输出与 `SettingsPageRegressionTests`，并检查运行日志。
- 结果：确认 H1/H2/H3 的代码证据；确认 H4 的指示器隐藏事实。未将截图渲染误当作真实滚动交互验收。

### E1：验证 H1

- 变量：只改变统计区域的高度约束，最多修改 1 行实验代码。
- 预期确认：扩大该区域后，底部面板内容能进入外层滚动内容范围。
- 预期拒绝：底部仍然不可达，或只是增加空白而没有改变内容可达性。
- 实验代码必须在记录结果后恢复，不作为正式修复。

### E1 结果

- 实验包成功构建并完成 1020×772 中文离屏渲染。
- 将最小高度提高后，语音时长排行榜的完整面板被纳入统计区域布局，截图中不再只出现面板上沿；这支持 H1，但离屏截图不能证明真实滚动手势的边界。
- 结论：H1 获得支持，仍需用实际布局结构实验确认是否应移除固定高度依赖，而不是简单提高常数。

### E2 结果：H2 不作为根因

- 真实窗口 CUA 无障碍读取在获取 SayAll 控件树时超时，无法用该路径测量 viewport；但当前截图中外层页面已经按窗口高度显示并能滚动，且问题只集中在统计页的复杂区域。
- 仅调整共享外层 `ScrollView` 会扩大影响范围，不能解释统计区域内部子内容超出固定高度的直接证据，因此不采用 H2 作为主修复。

### E3 结果：H3 与 H1 是同一布局机制

- `GeometryReader` 在纵向 `ScrollView` 内部使用固定高度提议，导致内部两个纵向面板的实际高度不参与父级内容高度计算；因此将统计两栏改为自定义 `Layout`，只读取宽度并返回两个子视图的实际最大高度。
- 该实验方向直接消除高度依赖，同时保留原有 42% / 最小 360pt 的宽度分配规则。

### E4 结果：H4 是可用性补充，不是根因

- 现有 `showsIndicators: false` 确实降低了“还有内容”的可发现性，但它不能解释内容被固定高度吞掉。
- 本次先修复内容高度报告；是否统一显示所有设置页滚动指示器不扩大本次 Bug 范围。

### E2：待执行，验证 H2

- 变量：只给 `settingsPage` 的纵向 `ScrollView` 增加填充高度约束。
- 预期确认：viewport 边界稳定，且统计页与其他设置页均保持正常布局。

### E3：待执行，验证 H3

- 变量：只移除统计页内部 `GeometryReader` 的高度依赖，保持宽度计算语义不变。
- 预期确认：内在高度由两个栏的实际内容决定，底部排行榜不再被父级高度吞掉。

### E4：待执行，验证 H4

- 变量：只显示纵向滚动指示器。
- 预期确认：用户能明确看到仍有可滚动内容；若底部内容仍不可达，则 H4 仅为可用性补充而非根因。

## Root Cause

统计页内部 `GeometryReader` 配合 `.frame(minHeight: 648)` 只向外层 `ScrollView` 报告固定高度，而右侧日历和单次语音排行榜的实际纵向内容可能更高，导致底部内容超出可滚动内容边界。

## Fix

用 `StatisticsColumnsLayout` 替换统计页内部的 `GeometryReader` 高度容器：布局仍按原规则计算左右栏宽度，但 `sizeThatFits` 返回两个栏的实际最大高度，使外层 `ScrollView` 能滚到语音排行榜及“查看全部回眸”按钮；同时保留页面现有底部 padding 和其他设置页布局。

## Verification

自动化将覆盖统计页布局声明、底部排行榜和“查看全部回眸”入口；离屏截图验证 1020×772 / 800×650 浅色和深色。当前环境的 CUA 真实滚动控件读取超时，需在测试包中补充人工滚动验收。

已完成验证：

- `swift test --disable-keychain --filter SettingsPageRegressionTests/profileStatisticsReportsIntrinsicHeightForBottomContent`：通过。
- `swift test --disable-keychain --filter SettingsPageRegressionTests`：43 项通过；为避免全局字符串断言误报，侧边栏 safe-area 回归断言已收窄到 `sidebar` 代码块。
- `git diff --check`：通过。
- Release 构建及 `scripts/verify-app.sh`：通过。
- `SettingsScreenshotRenderer`：已生成并检查 1020×772、800×650 的浅色 / 深色统计页截图；截图仅证明静态布局，不能替代真实滚动手势验收。
