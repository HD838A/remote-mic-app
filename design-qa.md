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
- 关于页把当前版本与检查更新放在同一区域，语言选项始终完整展示，通过本地化 Sheet 显示版本历史，提供可由系统 Markdown 应用打开的术语表，并提供普通启动是否自动打开主面板的开关；
- 所有界面文案使用稳定语义 key；当前语言缺少 Markdown 帮助时回退英文。

## 代码对应位置

- 窗口创建与最小尺寸：`Sources/RemoteMic/RemoteMicApp.swift`；
- 页面布局、材质和遥控器热点：`Sources/RemoteMic/SettingsView.swift`；
- 实体按键活动状态：`Sources/RemoteMic/HIDRemoteMonitor.swift` 与 `Sources/RemoteMic/BridgeAppModel.swift`。

## 结论

当前仓库截图对应 macOS 26 Liquid Glass 外观；同一页面结构在 macOS 14/15 自动切换到兼容样式。仓库未保留依赖本机临时目录的审查引用。
