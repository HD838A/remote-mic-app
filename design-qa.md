# Design QA：macOS 14 兼容与 macOS 26 Liquid Glass 设置页

[English](design-qa.en.md)

## 审查范围

- 设置窗口：最小尺寸 800×650，可自由缩放；
- 页面：连接与语音、按键映射、权限与隐私、关于；
- 仓库截图：
  - [连接与语音](Screenshots/connection-and-voice.png)
  - [按键映射](Screenshots/key-mapping.png)
  - [权限与隐私](Screenshots/permissions-and-privacy.png)

## 当前实现

- 设置页使用窄侧栏、标题区和分层内容区，四个页面的主要操作在最小窗口下可访问；
- 侧栏选择态和按键选择态使用低透明度语义蓝交互玻璃；
- 使用系统字体、语义字号和系统颜色，跟随浅色、深色、降低透明度与增强对比度设置；
- 窗口保留原生红黄绿按钮与逻辑标题，隐藏可见标题和标题栏分隔线，页面背景延伸到顶部；顶部空白背景可拖动窗口，交互内容仍避开窗口按钮；
- macOS 26 的面板和按钮使用原生 `glassEffect` 与 glass button style；macOS 14/15 使用系统 Material 与标准按钮，不使用自定义模糊实现；
- 按键页面复用 `Resources/RC003-remote-photo.png`，保持 508×1030 原始比例；
- 普通实体按键按下时会高亮遥控器示意图并定位映射行，语音键使用独立的语音活动状态；
- 界面未展示实物上不存在的独立静音键。
- 普通界面使用产品语言，不显示遥控器型号代号、蓝牙语音协议名、按键协议名、十六进制按键编号或设备标识术语；
- 关于页把当前版本、检查更新与默认关闭的预发布更新开关放在同一区域，语言选项始终完整展示，通过本地化 Sheet 显示版本历史，提供可由系统 Markdown 应用打开的术语表，并提供普通启动是否自动打开主面板的开关；
- 所有界面文案使用稳定语义 key；当前语言缺少 Markdown 帮助时回退英文。

## 代码对应位置

- 窗口创建与最小尺寸：`Sources/RemoteMic/RemoteMicApp.swift`；
- 页面布局、材质和遥控器热点：`Sources/RemoteMic/SettingsView.swift`；
- 实体按键活动状态：`Sources/RemoteMic/HIDRemoteMonitor.swift` 与 `Sources/RemoteMic/BridgeAppModel.swift`。

## 结论

当前仓库截图对应 macOS 26 Liquid Glass 外观；同一页面结构在 macOS 14/15 自动切换到兼容样式。仓库未保留依赖本机临时目录的审查引用。

---

# Design QA：iOS“无线麦”信息页

## 对比依据

- 设计参考：`/Users/andy/.codex/attachments/7432b5da-5217-4ea9-bda5-5d2e66244709/codex-clipboard-c4585fd9-734e-41dc-91a6-e09e0c690845.png`
- 实现截图：`Apps/RemoteMicIOS/.codex-screenshots/runs/20260804-021737/002-mac-app-detail-iphone12.png`
- 全屏并排对比：`Apps/RemoteMicIOS/.codex-screenshots/runs/20260804-021737/004-full-comparison.png`
- 顶部重点对比：`Apps/RemoteMicIOS/.codex-screenshots/runs/20260804-021737/007-top-comparison.png`
- 视口：iPhone 12，390×844 pt，截图 1170×2532 px，@3x。
- 参考图：853×1844 px；对比时仅为并排观察归一化到 1170×2532 px，未作为 App 资产使用。
- 状态：参考图为已连接，实现截图为正在查找；连接文案和状态色差异属于运行状态差异，结构、字号和布局在同一页面状态下评估。

## 全屏与重点区域结论

- 信息层级、顶部导航、Logo、连接信息、检查项、推荐说明、下载链接和操作按钮均完整显示，固定单屏没有裁切或滚动。
- 四个主要信息区恢复为清晰卡片分块，统一使用 16pt 页面边距、10pt 卡片间距、14pt 连续圆角，以及 14pt 水平/10pt 垂直内部留白；左右边缘、分栏和操作按钮均保持对齐。
- 标题已改为“无线麦”；详情页 Logo 与顶部切口彩蛋均复用 `AppLogo`，使用与 App Icon 相同的连续圆角矩形轮廓。
- 字体继续使用系统字体，字号、字重、行高与现有遥控器页面一致；文案没有截断或异常换行。
- 颜色继续使用现有铝合金背景、石墨按钮和语义绿/橙状态色，没有引入新的视觉体系。
- 顶部重点对比确认返回、标题、刷新按钮、Logo 和连接状态的对齐清晰；刘海/灵动岛彩蛋为完全不透明显示；左侧边缘右滑已在模拟器实际返回遥控页。

## 比较与修正记录

1. 首轮实现截图 `Apps/RemoteMicIOS/.codex-screenshots/runs/20260803-232254/002-mac-app-detail-iphone12.png`：已统一圆角并修改标题，但仍保留四个大小不同的大卡片；用户明确要求去掉分块，因此该轮不通过。
2. 第二轮实现截图 `Apps/RemoteMicIOS/.codex-screenshots/runs/20260804-011536/002-mac-app-detail-iphone12.png`：按当时要求移除大卡片并完成左侧边缘返回，但用户后续确认连续布局过于拥挤，因此继续调整。
3. 当前实现截图 `Apps/RemoteMicIOS/.codex-screenshots/runs/20260804-021737/002-mac-app-detail-iphone12.png`：恢复四张卡片并统一外边距、卡片间距、圆角和内部留白；页面在 iPhone 12 首屏完整显示，左滑返回与顶部不透明彩蛋均通过验证，未发现仍需处理的 P0/P1/P2 问题。

## 剩余轻微差异

- 参考图没有 iOS 状态栏与顶部切口彩蛋；实现保留系统状态栏，并按用户要求在刘海/灵动岛位置完整显示彩蛋。这是平台与产品要求导致的预期差异。

final result: passed
