# 快捷指令私有模块集成

## 为什么开发

快捷指令需要在无线麦中配置、测试并绑定遥控器，但邀请码资格、输入框学习、宏执行和本地私有数据不应进入公开源码仓库。

## 用户功能介绍

包含私有模块的内测构建会为已有资格用户保留邀请码状态，并通过受控入口显示邀请码录入区域。资格有效后，侧边栏显示“组合动作”，用户可以创建多步骤动作、录入快捷键、学习输入框、按 Identifier 运行本机快捷指令、使用默认浏览器打开指定网址，并绑定到遥控器的单击、双击或长按。资格关闭或模块缺失时，原有按键映射继续工作。

## 范围与非目标

- 公开仓库只维护可选 Swift Package 接入、页面委托、按键事件转发和关闭状态回归。
- 私有 `sayall-macro-platform` 维护邀请码、Feature Flag、页面、宏库、执行器、输入框学习和本地存储。
- 本次不发布预览版，不开放市场、社区上传或任意脚本。

## 关键设计

- 构建时通过 `SAYALL_MACRO_PLATFORM_PATH` 可选加载 `SayAllMacroRemoteMic`。
- 运行时使用独立快捷指令资格；没有有效资格时私有模块不接管任何按键。
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

- 公开仓库不包含邀请码校验、资格令牌、宏定义、输入框学习数据或私有页面实现。
- 未授权、资格失效和未注入模块三种状态都不修改现有按键配置，也不影响 HID、蓝牙和音频监控。
- 快捷指令本机数据由私有模块保存；不会上传快捷键、输入框特征或按键记录。
- “运行快捷指令”只调用系统固定 `/usr/bin/shortcuts`，Identifier 作为独立进程参数传递，不开放任意命令。导入导出保留快捷指令名称和 Identifier，并标记为依赖本机快捷指令，不携带快捷指令本体。
- “打开网址”只接受用户明确填写的 `http` / `https` 完整网址，并交给系统默认浏览器；拒绝本地文件、自定义 Scheme、账号密码、缺少 Host、控制字符和超长网址，不经过 shell 或脚本解释。
- 邀请资格客户端兼容生产服务带小数秒的 ISO 8601 时间；失败时显示状态并写入脱敏日志，不记录邀请码或资格凭据。
- 私有资源从最终 App 的 `Contents/Resources` 解析，并兼容 SwiftPM 生成的 `zh-hans.lproj`；邀请码标题、状态和按钮不得回退为原始本地化 key。
- 私有页面不得直接调用 SwiftPM `Bundle.module`；宿主构建会拒绝绕过标准 App 资源解析器的快捷指令页面，避免发布机器绝对构建路径掩盖崩溃。
- 邀请码输入、验证、状态和隐私说明集中在一个紧凑卡片中；宿主提供标准 Edit 菜单，让聚焦文本框支持复制、粘贴、剪切、撤销、重做和全选。

## 当前状态

代码和本地 App 打包接入完成。2026-08-14 已修复生产资格时间解析导致的“服务端兑换成功但客户端无反应”，并同步覆盖共享资格客户端；随后修复邀请码本地化 key 原样显示、标准文本编辑快捷键缺失和卡片过松问题。`1.8.22 (114)` 暴露出实际组合动作页面仍绕过标准资源解析器，点击后会崩溃；当前修复已统一页面资源入口，并增加私有模块与宿主构建双重门禁。2026-08-16 新增按 Identifier 运行本机快捷指令、自动刷新、可用状态、单步测试和本机依赖声明，并在常用功能加入受限的“打开网址”。真实快捷指令、真实默认浏览器、首次隐私授权、跨 Mac 导入和 `800 × 650` 页面仍待人工验收。等待新的 Developer ID 安装包、有效资格真实入口点击、Intel、真实遥控器及第三方 App 输入框人工验收。
