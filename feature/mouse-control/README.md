# 鼠标控制：点击动作与鼠标模式

## 为什么开发

用户需要把遥控器变成简易鼠标：一是把"鼠标左键/右键/中键点击"作为预设动作绑定到任意按键；二是通过"鼠标模式"用方向键直接移动光标、OK 键点击，覆盖不便摸鼠标（演示、客厅、躺姿）的场景。

## 用户功能

- 按键映射的"系统与媒体"分组新增三个动作：鼠标左键、鼠标右键、鼠标中键；按下绑定键时在光标当前位置点击一次，支持单击/双击/长按绑定。
- 新增内部动作"切换鼠标模式"（不改变其他配置，绑定方式与其他动作相同）：
  - 进入后方向键按住即移动光标，速度按二次缓入曲线加速（160px/s 起步、约 1.2 秒达到 1400px/s，前 0.3 秒为精调区），支持斜向，屏幕边缘自动停止。
  - OK 键三手势（固定不可配置）：单击（快速松开后 300ms 内无第二击）= 松开时刻光标位置的左键点击；双击（第二次也快速松开）= 右键点击；任何一次按下按住 ≥550ms = 注入 Return（微信等聊天工具的发送消息），长按优先、触发后不再产生点击。菜单键 = 正常绑定（不再拦截为右键），返回键 = 正常绑定，退出鼠标模式只靠再次按切换键。切换键建议绑在非受管键（菜单 / TV / 主页 / 音量等）上。
  - 模式激活期间音量、主页等其他键保持原功能；菜单栏图标切换高亮样式提示当前处于鼠标模式。
  - 模式内方向键支持按前台 App 分上下文的固定双击手势（不可配置，判定时实时读取前台 App）：前台是 Chrome / Safari / Helium 时，双击上 = 回顶部（Command-↑）、双击下 = 回底部（Command-↓）、双击左 = 后退（Command-[）、双击右 = 关闭标签页（Command-W）；前台是微信时，双击上 = Page Up、双击下 = Page Down，双击左右无动作；其他 App 里双击完全无动作（等效于两次普通短按移动，不弹回不注入）。判定对齐 App 现有手势识别器的 300ms 双击窗口：第一次按下到松开 < 300ms 记为轻点，第二次按下距第一次松开 ≤ 300ms 触发；只有确实有动作要执行时才把光标弹回第一次按下前的位置，且第二次按下期间该方向不移动，松开后恢复正常；第一次为长按（≥300ms）不构成轻点。
- 鼠标模式只作用于实体遥控器 HID 链路；手机、Apple Watch、网页遥控不受模式影响，但其按键仍可绑定鼠标点击动作。

## 范围与非目标

- 不做屏幕浮窗 HUD；不实现拖拽（按住 OK 拖动）；不改变手机/手表/网页协议。
- 鼠标模式不持久化"激活状态"：App 重启、遥控器断开时一律回到关闭。

## 关键设计与涉及文件

- `Sources/RemoteMic/RemoteButtons.swift`：`ButtonAction` 新增 `mouseLeftClick`、`mouseRightClick`、`mouseMiddleClick`、`toggleMouseMode`；前三个归入 `systemAndMedia`，最后一个为 `isAppInternal` 内部动作。
- `Sources/RemoteMic/KeyboardInjector.swift`：新增 `postMouseClick`，复用 `.cghidEventTap` 注入与 `syntheticEventMarker` 标记、辅助功能权限检查。
- `Sources/RemoteMic/MouseModeController.swift`：新状态机（`idle`/`active`），60Hz 移动引擎（二次缓入：160px/s 起步，约 1.2 秒达到 1400px/s），坐标钳制到屏幕边界，方向 down/up 驱动；方向键双击检测复用 `HIDRemoteTiming.doubleClickMilliseconds`（300ms）作为轻点时长与双击窗口，映射表按实时前台 App 分派（浏览器集合 / 微信 / 其他无动作），有动作时经可注入 `keyPoster` 走 `KeyboardInjector.postKey` 链路注入并把光标弹回第一次按下前位置，无动作时第二次按下正常参与移动；OK 三手势状态机复用同一 300ms 窗口做单击待决左键 / 双击右键判定，复用 `HIDRemoteTiming.longPressMilliseconds`（550ms）做长按发送判定。
- `Sources/RemoteMic/HIDRemoteMonitor.swift`：模式激活时在 `process(usages:)` 入口拦截方向/OK 键（菜单、返回键已恢复走正常绑定路径），不透传、不进入手势识别。
- `Sources/RemoteMic/BridgeAppModel.swift`：`toggleMouseMode` 经 `onInternalAction` 接线到控制器，驱动菜单栏图标状态。
- `Resources/*/Localizable.strings`：四个新动作的中英文案。
- `Tests/RemoteMicTests/MouseModeControllerTests.swift`：状态机、加速数学（注入时钟与事件 poster）、边界钳制、编解码。
- `Testing/MouseControlMode.md`：真实遥控器测试手册。

## 兼容边界

- `ButtonAction` 为字符串 raw 枚举 JSON 持久化：包含新动作的配置被旧版 App 读取时，本地绑定与设备 profile 会整体回退默认；旧版导入新版导出的配置会整体失败并报错（既有前向不兼容行为）。不配置新动作的用户不受任何影响。
- 鼠标事件注入与键盘注入同样需要辅助功能权限；权限缺失时复用现有提示链路。
- 多遥控器共用同一个鼠标模式：任一遥控器断开都会立即退出模式（fail-safe）。方向键按住状态无法归属到具体设备，断开即清空是安全选择，避免设备切换后幻影移动。

## 验证状态

- 单元测试：`Tests/RemoteMicTests/MouseModeControllerTests.swift` 共 34 个用例（状态机进出、辅助功能权限缺失拒绝、方向 down/up 驱动移动、二次缓入加速锚点（t=0→160、t=0.6s→470、t=1.2s→1400、饱和 1400）、斜向归一化、屏幕边界钳制（钳到 maxX-1）、OK 三手势（单击待决 300ms 后左键/双击右键且不误触左键/第二击长按发送/窗口外第二击为再次单击/长按优先/deactivate 清待决）、菜单与返回键穿透且只有切换键退出、非管理键穿透、停用后取消 tick、点击注入与权限 guard、`toggleMouseMode` 内部动作边界、displayName/category/Codable 往返、tick delta 0.05s 上限、光标位置缺失时不移动不点击、HID 监视器 flush 清除幻影长按/双击/连发/非连发锁存、方向键双击分上下文（浏览器四方向、Safari/Helium 同表抽查、微信上下翻页、微信左右无动作、非目标 App 无动作且正常移动）、300ms 窗口内/外边界、第一次长按不构成轻点、单击超时无动作、模式外不响应），已通过。
- 回归：ShortcutCaptureMonitorTests、VoiceFnTapSessionControllerTests、RemoteButtonGestureRecognizerTests、LocalizationTests（含中英文键一致性）以及 Self Test（42 项）均通过；合并运行共 61 项 swift-testing 用例全过。
- 2026-08-22 键位重设计：受管键从 {方向×4, OK, 菜单, 返回} 缩减为 {方向×4, OK}；菜单/返回键在模式内恢复正常绑定（HIDRemoteMonitor 拦截分支不变，仅 controller 的 managedButtons 与 handle 调整）；退出鼠标模式只剩切换键；OK 改为三手势状态机（单击待决左键 / 双击右键 / 长按 Return 发送，详见用户功能一节）。
- 2026-08-22 移动手感：速度曲线从线性（240→1200px/s，1s）改为二次缓入（160→1400px/s，1.2s，`speed = initial + (max-initial) × progress²`），前 0.3 秒为精调区；tick 积分、delta 上限、斜向归一化与边界钳制不变。此前的系统级 harness 位移实测值基于旧线性曲线，曲线常量的真机手感需重新验收。
- 2026-08-22 双击手势分上下文：方向键双击映射从全局（Page Up/Down、Command-[、Command-W）改为按实时前台 App 分派——浏览器集合（Chrome/Safari/Helium）用回顶部/回底部/后退/关闭标签页，微信用 Page Up/Page Down 且左右无动作，其他 App 双击完全无动作（不弹回不注入、第二次按下正常移动）；新增可注入 `frontmostBundleIdentifier`（默认读取 NSWorkspace 前台 App），弹回只在有动作时发生。
- 2026-08-22 复审修复：模式激活/退出两个时机冲刷 HID 在途输入状态（`flushInFlightInputState`，保留 activeUsages）；`HIDRemoteMonitor.stop()` 与 `disconnectSimulatedDevice()` 现在也会退出鼠标模式（覆盖权限回收/动作失败路径）；菜单栏图标在鼠标模式下使用独立无障碍文案与 `cursorarrow` 回退符号；坐标钳制到 maxX-1；光标位置取不到时跳过移动与点击。
- 本机工具链限制：当前机器只有 Swift 6.1（Xcode 16.4），仓库 Package 要求 6.2，因此 `xcrun swift build` / `swift test` 未在本机直接执行；上述测试是用手工链接的等效测试可执行文件（同一源码、同一 swift-testing 框架）跑过的，且整个 `RemoteMic` 模块（含 `BridgeAppModel` / `RemoteMicApp` 改动）已通过 `swiftc -typecheck`；仅 `SettingsView.swift` 因使用 macOS 26 SDK API 无法被本机 SDK 编译（既有现象，与本次改动无关）。CI（Swift 6.2）上的完整 `swift test` 仍待执行。
- 2026-08-22 真实系统级 harness（真实 CGEvent 注入、真实 60Hz 计时器、真实 NSScreen 边界）：左移 0.5s 实测 244px（理论 240px），右移 1.5s 实测 900px 并真实观察到屏幕右边界钳制，斜向两轴等距归一（244/√2≈172），OK 键真实左键注入、back 退出后 tick 停止且光标零位移，测试后光标恢复原位，全部断言通过。注意：该 harness 跑的是钳制改为 maxX-1 之前的构建，差异仅 1px，不影响其结论。
- 真机验收：未执行。真实遥控器 HID 边沿输入、移动手感、点击落点、模式拦截、图标切换、多显示器与稳定功能回归需按 `Testing/MouseControlMode.md` 完成人工验收。
