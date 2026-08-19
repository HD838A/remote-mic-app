# 组合动作私有模块集成

## 为什么开发

组合动作需要在无线麦SayAll.app 中配置、测试并绑定遥控器，但输入框学习、宏执行和本地私有数据不应进入公开源码仓库。

## 用户功能介绍

包含私有模块的 App 会直接显示“组合动作”侧边栏，不需要邀请码，也不会显示组合动作邀请码录入区域。用户可以创建多步骤动作、录入快捷键、学习输入框、按 Identifier 运行本机快捷指令、使用默认浏览器打开指定网址、复用已有组合动作，并绑定到遥控器的单击、双击或长按。模块缺失时不显示入口，原有按键映射继续工作。

## 范围与非目标

- 公开仓库只维护可选 Swift Package 接入、页面委托、按键事件转发和缺少模块时的回归。
- 私有 `sayall-macro-platform` 维护页面、宏库、执行器、输入框学习和本地存储；旧资格客户端仅为兼容保留，不再控制组合动作访问。
- 本功能不开放市场、社区上传或任意脚本。

## 关键设计

- 构建时通过 `SAYALL_MACRO_PLATFORM_PATH` 可选加载 `SayAllMacroRemoteMic`。
- 组合动作运行时不检查邀请码资格；私有模块存在时入口和本机执行直接可用。
- 组合动作启动不会显示兑换入口，不会因为打开页面创建设备身份或请求资格服务。
- 公开构建未注入私有模块时使用安全 no-op 适配器，保持 SwiftPM 构建和稳定功能不变。
- 按键绑定使用遥控器 Profile ID、按键 raw value 和触发方式传递，不让两个仓库互相依赖内部类型。

## 涉及文件

- `Package.swift`
- `Sources/RemoteMic/MacroFeatureIntegration.swift`
- `Sources/RemoteMic/HIDRemoteMonitor.swift`
- `Sources/RemoteMic/BridgeAppModel.swift`
- `Sources/RemoteMic/SettingsView.swift`
- `Sources/RemoteMic/RemoteMicApp.swift`
- `scripts/build-app.sh`
- `scripts/verify-app.sh`
- `scripts/check-repository-boundaries.sh`
- `Tests/RemoteMicTests/BuildSigningTests.swift`
- `Tests/RemoteMicTests/HardwareSimulationIntegrationTests.swift`
- `Tests/RemoteMicTests/SettingsPageRegressionTests.swift`

## 隐私和兼容边界

- 公开仓库不包含宏定义、输入框学习数据或私有页面实现。
- 旧组合动作资格数据是否存在或有效都不改变入口和执行；未注入模块时不接管按键，也不影响 HID、蓝牙和音频监控。
- 组合动作免邀请码不改变其他受邀私有功能的独立 Feature Flag、资格策略或默认关闭状态。
- 快捷指令本机数据由私有模块保存；不会上传快捷键、输入框特征或按键记录。
- “运行快捷指令”只调用系统固定 `/usr/bin/shortcuts`，Identifier 作为独立进程参数传递，不开放任意命令。导入导出保留快捷指令名称和 Identifier，并标记为依赖本机快捷指令，不携带快捷指令本体。
- “打开网址”只接受用户明确填写的 `http` / `https` 完整网址，并交给系统默认浏览器；拒绝本地文件、自定义 Scheme、账号密码、缺少 Host、控制字符和超长网址，不经过 shell 或脚本解释。
- “执行已有组合动作”按稳定 ID 解析最新已保存版本；保存前和执行时均阻止循环，最多 8 层。导入导出只记录名称与 ID，不复制被引用动作或按同名项目猜测执行。
- 私有资源从最终 App 的 `Contents/Resources` 解析，并兼容 SwiftPM 生成的 `zh-hans.lproj`。
- 私有页面不得直接调用 SwiftPM `Bundle.module`；宿主构建会拒绝绕过标准 App 资源解析器的快捷指令页面，避免发布机器绝对构建路径掩盖崩溃。
- 宿主提供标准 Edit 菜单，让组合动作中的聚焦文本框支持复制、粘贴、剪切、撤销、重做和全选。
- 宿主在组合动作页固定说明输入框学习与回眸 MCP 的职责边界：前者只用于定位目标输入位置，后者只授权 Agent 读取本地历史，配置任一项都不会自动完成另一项。

## 当前状态

代码和本地 App 打包接入完成。历史邀请码流程的时间解析、本地化和资源加载问题已经修复；`1.8.22 (114)` 暴露的组合动作页面资源崩溃也已通过统一资源入口和双重构建门禁修正。2026-08-16 新增按 Identifier 运行本机快捷指令、受限“打开网址”以及复用已有组合动作；嵌套执行按最新已保存版本解析，并防止循环和过深嵌套。2026-08-18 起组合动作不再要求邀请码，模块存在时直接显示入口并允许本机执行；旧资格客户端和本机数据只为兼容保留。2026-08-19 宿主页面补充输入框学习与回眸 MCP 的职责边界说明，不改变私有宏执行或 MCP 配置。真实快捷指令、真实默认浏览器、首次隐私授权、跨 Mac 导入、嵌套遥控器链路、Intel、真实遥控器、第三方 App 输入框及 `800 × 650` 页面仍待人工验收。
