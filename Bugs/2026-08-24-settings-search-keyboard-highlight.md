# 设置搜索缺少键盘闭环、命中高亮与后退历史菜单

## 复现

- 环境:macOS 27,「系统设置」同屏对照;`dist/SayAll.app` 调试构建。
- 操作:在侧栏搜索输入具体设置名;按回车;用方向键浏览结果;点击结果观察目标分区;长按标题栏「后退」。
- 实际结果:回车不激活任何结果;结果列表无选择态,↑↓ 与 Return 无效;命中后只滚动、无系统设置式高亮提示;「前进」有历史菜单而「后退」没有;搜索目录遗漏「语音键模拟 Fn 点按」「恢复默认」「统计分享」「全部删除」「官网」「GitHub」等设置项。
- 预期结果:回车激活首个结果,列表支持键盘导航,命中分区短暂高亮,后退/前进对称提供历史,目录覆盖全部可操作设置。

## 日志结论

纯界面交互问题,无专用日志;核对 runtime.log 无相关错误。

## 根因

- `.searchable` 未配 `onSubmit(of: .search)`;结果 `List` 无 `selection`,行是普通 Button,键盘事件无从附着。
- `scrollToSearchResult` 只调用 `proxy.scrollTo`,没有任何视觉定位反馈。
- 标题栏后退是纯 `Button`(前进是 `Menu + primaryAction`),历史模型只暴露了 forward 索引。
- 搜索目录是静态清单,新增功能行后未同步补入。

## 修复

- `.searchable` 追加 `onSubmit(of: .search)` 激活首个结果;结果列表改 `List(searchResults, selection:)`,↑↓ 移动选择,`.onKeyPress(.return)` 激活选中项;⌘F 经协调器聚焦搜索框(见菜单对齐文档)。
- 命中高亮:新增 `searchAnchor(_:highlighted:)` 合并修饰符(id + 短暂 accent 描边淡出),20 个目录锚点与新增「统计分享」锚点统一接入;`flashSearchResultHighlight` 0.9 秒后 0.6 秒淡出。
- 后退按钮改 `Menu + primaryAction`,新增 `backwardHistoryIndices`,与前进对称;⌘[/⌘] 经显示菜单生效。
- 目录补全 6 项:`mapping.voice-fn`、`mapping.restore-defaults`、`statistics.share`、`transcripts.delete-all`、`about.website`、`about.github`。

## 验证

- 修复前源码门禁无这些结构;修复后 31 项设置页定向测试(含 onSubmit、selection、backwardHistoryIndices、searchAnchor、6 个新目录项断言)、344 项全量测试通过。
- Xcode 27 工具链成品构建、完整性校验与 `git diff --check` 通过;中文浅色/深色、英文 `800 × 650` 离屏渲染与真实窗口逐页检查通过。

## 验证边界

本会话无辅助功能权限,搜索框真实键盘输入、↑↓/Return 激活、长按后退历史、高亮淡出的动态过程未做代理实测,按测试手册人工复核;macOS 14 的 ⌘F 为禁用态属预期。
