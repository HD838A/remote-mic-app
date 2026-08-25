# 关于页版本历史 Sheet 与导航行语义不符、检查更新可重复点击

## 复现

- 环境:macOS 27,「系统设置」同屏对照;`dist/SayAll.app` 调试构建。
- 操作:打开「关于」,查看「版本历史」行(右侧带系统前进指示);点击;连续点击「检查更新…」。
- 实际结果:chevron 导航行弹出的是 640×520 固定尺寸模态 Sheet(自绘头部与关闭按钮),与「前进指示 = 页内导航」的系统语义不符;检查更新按钮在检查中仍可点击,可并发触发多次检查。
- 预期结果:版本历史作为关于页子页面进入统一导航历史,标题栏返回/前进可回退;检查中按钮禁用。

## 日志结论

纯界面结构问题,无专用日志;runtime.log 无相关错误。

## 根因

- 版本历史是原生设置重构前的 `.sheet(isPresented:)` 遗留,行 affordance 已在上一轮改为系统导航行,但行为未跟进。
- 当时「检查更新…」「重新检查」两个按钮未根据 `updateInformation.state == .checking` 禁用；2026-08-25 已进一步合并为单一状态化更新按钮。

## 修复

- `SettingsSection` 新增 `releaseHistory` 伪页面(不出现在侧栏 `sidebarSectionOrder`):`titleKey = about.version.history`,侧栏选择映射回「关于」,`pageTopAnchor = release-history-list`。
- 关于页 chevron 行改为 `navigate(to: .releaseHistory)`,纳入统一导航历史,标题栏后退/前进自然回退;`ReleaseHistorySheet` 重写为无头部的 `ReleaseHistoryContent`,新 `releaseHistoryPage` 使用 700pt 内容列与隐藏滚动条;删除 `.sheet` 与 `isReleaseHistoryPresented`。
- 新增 `isCheckingForUpdates`；2026-08-25 的最终交互只保留一个 `.disabled(isCheckingForUpdates)` 的状态化按钮。

## 验证

- 修复前:chevron 行开 Sheet,检查中可重复点击。
- 修复后结构门禁:`case releaseHistory`、`releaseHistoryPage`、`navigate(to: .releaseHistory)` 存在,`isReleaseHistoryPresented`/`ReleaseHistorySheet` 不存在,`.disabled(isCheckingForUpdates)` 恰好两处;31 项定向测试、344 项全量测试通过。
- Xcode 27 工具链成品构建与完整性校验通过;真实窗口与三种外观/语言 `800 × 650` 离屏渲染通过。

## 验证边界

子页面真实点击、返回/前进连锁导航未做代理实测(无辅助功能权限),按测试手册人工复核;发布历史内容解析逻辑未改,Markdown 缺失时的错误文案路径沿用既有实现。
