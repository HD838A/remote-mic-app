# 设置导航、搜索与 Liquid Glass 未对齐系统设置

## 复现

1. 在 macOS 27、`800 × 650` 设置窗口中并排打开无线麦SayAll.app 与系统设置。
2. 比较标题栏导航、侧栏、搜索框和页面切换。
3. 在无线麦中搜索“增益”，再从连接页进入按键页并尝试返回。

修复前可重复观察到：侧栏实际只有约 144pt；工具栏出现系统设置当前结构中没有的侧栏开关；搜索仅按页面标题过滤并会替换侧栏导航；页面只有一个扁平选择值，没有可用的返回/前进历史；后续手工导航版本又呈现为分离、悬空的旧式按钮，缺少 macOS 26/27 的整组 Liquid Glass 关系。

## 日志与现场证据

这是界面结构问题，`~/Library/Logs/RemoteMic/runtime.log` 没有对应运行时错误。修复前辅助功能树显示 splitter 为约 `144`，且 toolbar 暴露自动侧栏开关；这与视觉差异一致，排除业务数据状态导致布局变化。

## 根因

1. 设置导航只保存单一 `selectedSection`，没有历史栈；搜索只对侧栏页面标题做字符串过滤，无法表达系统设置的“具体设置项 → 所属页面”关系。
2. 侧栏宽度和 `.toolbar(removing: .sidebarToggle)` 曾挂在错误的视图层级，SwiftUI 没有把它们应用到实际 sidebar 列。
3. 前进/返回曾被当作独立图标按钮处理；后续虽然换成原生控件，正式构建仍因 `--triple arm64-apple-macosx14.0` 把 Mach-O 同时标成 `minos 14.0 / sdk 14.0`，macOS 27 因而按旧链接应用渲染搜索框和工具栏。给控件套 `glassEffect` 只能得到错误的 68×30pt 外壳，无法复现系统设置约 75×38pt、带中央分隔线的导航组。

## 修复

- 把列宽与侧栏工具栏移除修饰符直接挂到 sidebar 列；保留原生 `.sidebar` List 和 `.searchable(placement: .sidebar)`。
- 建立可前进、返回和截断分支的页面历史；使用原生 `ControlGroup(.navigation)` 和带 primary action 的前进 `Menu`。
- 建立具体设置项索引；搜索结果展示名称与所属页面，点击后导航并通过 `ScrollViewReader` 定位分区，同时保留查询和右侧详情。
- macOS 26/27 使用系统 `ControlGroup(.navigation)`、`.buttonStyle(.glass)` 与 `.controlSize(.extraLarge)`；不再给导航组绘制 `glassEffect` 外壳或桥接 `NSSegmentedControl`。
- 构建脚本从当前 Xcode 读取 macOS SDK 路径与版本，并明确写入链接平台版本；复制成品前用 `vtool` 校验部署下限和 SDK 链接版本，既保留 macOS 14 兼容性，也允许 macOS 26/27 使用当前原生外观。
- 删除旧手工侧栏按钮、圆形边框和 responder-chain action，不给内容区增加自绘模糊或玻璃卡片。

## 验证

- Xcode 27 调试构建成功，Mach-O 为 `minos 14.0 / sdk 27.0`，真实 App 可启动。
- 真实辅助功能树显示 splitter 为 `232`，toolbar 只包含返回与前进导航组，不再出现侧栏开关。
- 从连接进入按键后返回键启用；搜索“增益”显示具体结果，点击后进入连接页，返回可回到按键页且前进启用。
- 浅色真实窗口确认搜索框恢复系统圆角，标题、侧栏图标和原生导航组位于同一系统网格；导航组的尺寸、胶囊轮廓和中央分隔线与同机系统设置一致。
- 30 项设置页定向测试、18 项构建门禁测试与 343 项全量测试（32 个 suite）通过；App 完整性、两种语言资源、Swift 语法、构建脚本语法和 `git diff --check` 通过。
- 最终浅色真实最小窗口逐页进入全部公开设置入口，splitter 始终为 `232`，窗口几何未变化；搜索“增益”、结果深定位、返回和前进均完成真实交互复核。

## 验证边界

本问题不修改蓝牙、HID、音频、权限、iPhone、Apple Watch 或网页连接逻辑。自动化、完整 App 检查、深色逐页检查和离屏截图结果以 `Testing/NativeSettingsInterface.md` 最新小节为准；没有执行的真实硬件流程不得标记为通过。
