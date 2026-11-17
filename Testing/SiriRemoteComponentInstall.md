# Siri Remote 组件安装模块

- 适用版本/分支：本 PR 或已合入 `main` 的精确 Commit；历史分支只作为对应 PR 的审计证据。
- 适用页面：设置 → 连接与语音，左侧设备列表下方。
- 产品行为以 [遥控器连接生命周期规范](../feature/remote-connection-lifecycle/PRODUCT_SPEC.md) 为准。

## 测试前准备

1. 准备一台未安装 Siri Remote 系统 helper / LaunchDaemon、但已安装无线麦 SayAll 的测试 Mac；优先使用独立测试机或虚拟机，不要在用户机器上手工删除系统文件。
2. 准备真实 A2854 或 A2540、目标语音工具和受支持的虚拟音频设备。
3. 打开运行日志：`~/Library/Logs/RemoteMic/runtime.log`。
4. 记录 App 版本、Build、macOS 版本、遥控器型号和组件安装前状态。

## 用例 1：升级用户看到安装模块

1. 在未安装 Siri Remote 组件的环境打开“连接与语音”。
2. 查看左侧“连接过的设备”下方。

预期：

- 出现普通面板样式的“安装 Siri Remote 组件”模块。
- 模块说明只要求一次管理员授权，不出现下载 PKG、会员或旧版本说明。
- 模块与左侧其他面板一致，没有强调色。
- 不显示卸载按钮。
- 遥控器卡片、按键映射、语音设置和其他页面保持原样。

失败判定：模块缺失；模块使用强调色；出现“启用”“卸载”或其他卡片动作；改动左侧历史设备卡。

## 用例 2：安装成功

1. 点击“安装组件”。
2. 在系统管理员授权窗口允许一次授权。
3. 等待安装完成。

预期：

- 授权前按钮禁用并显示等待授权状态。
- 系统 helper 和 LaunchDaemon 安装完成。
- 模块自动且完全消失，不显示“已安装”或卸载按钮。
- 已有的小米、Chromecast 设备、按键映射和语音设置不受影响。
- 重新启动 App 后模块仍不显示。

失败判定：授权后模块仍显示；出现卸载按钮；安装失败却报告成功；模块隐藏但 helper/LaunchDaemon 缺失。

## 用例 3：取消与重试

1. 在管理员授权窗口点击取消。
2. 返回 App 查看模块。
3. 点击“重试”并允许授权。

预期：

- 取消后模块保留，按钮改为“重试”，并说明取消后不会自动重复弹窗。
- 重新启动 App 后不自动弹出授权窗口。
- 只有用户再次点击“重试”才重新请求授权。
- 重试成功后模块完全消失。

失败判定：取消后自动反复弹窗；取消后模块消失但组件未安装；重试没有重新请求授权。

## 用例 4：已安装环境

1. 使用已安装 Siri Remote 系统 helper 和 LaunchDaemon 的环境打开“连接与语音”。
2. 检查左侧设备列表下方。

预期：

- 不显示安装模块。
- 不显示卸载按钮。
- 遥控器卡片和其他页面保持原样。

失败判定：组件已安装仍显示安装模块；出现卸载入口。

## 用例 5：回归

1. 连接 RC001、RC003 或其他已支持的小米遥控器，验证连接、普通按键和语音。
2. 连接 Chromecast 语音遥控器，验证连接和语音。
3. 打开“按键映射”、语音设置、输出设备和手机连接。
4. 重复中文/英文、浅色/深色和最小生产窗口 `1067 × 760`。

预期：

- 本次只新增安装模块，不改变遥控器卡片、按键、触摸、语音、音频输出、会员入口和手机连接。
- 模块不遮挡左侧历史设备或右侧语音设置。
- 中文文字不小于 12pt，英文不截断关键说明。
- 面板在 `1067 × 760` 下可完整查看和滚动。

失败判定：任一既有设备或语音路径回退；模块导致页头、卡片或右侧面板位移；文字被裁切；新增卸载按钮。

## 日志收集

记录每个用例的开始/结束时间和对应日志。重点核对：

- `APPLE REMOTE COMPONENT_INSTALL phase=requested action=install source=connection_page`
- `SIRI REMOTE ACTIVATION phase=changed enabled=true`
- `APPLE REMOTE HCI upgrade phase=checking`
- `APPLE REMOTE HCI upgrade phase=ready result=installed_version_verified`
- `SIRI REMOTE AUDIO phase=ready result=capture_available`
- 取消或失败时的 `authorization_helper_upgrade_*` 原因码和等待状态。

日志不得包含设备名、设备标识、用户内容、路径或凭据。

## 自动化与真实环境边界

- `AppleRemoteComponentInstallationTests` 验证 helper 与 LaunchDaemon 双路径检测。
- 公开全量 Swift 测试和 `scripts/verify-localizations.sh` 验证编译、文案和既有回归。
- 生产设置页离屏入口使用 `REMOTE_MIC_SETTINGS_SCREENSHOT_APPLE_REMOTE_COMPONENT=missing|installed`、`REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION=connection`、尺寸 `1067 × 760` 生成静态截图；只证明布局和状态，不证明真实安装。
- 真实管理员授权、SMJobBless、Sparkle 升级、真实 A2854/A2540 语音、取消/重试和不同 macOS 版本必须在签名并公证的测试包上人工验收；未完成前只能标记为候选。
- 组件级卸载不在本模块范围，已记录在 `TODO.md`，不提供按钮，也不在测试中执行卸载。
