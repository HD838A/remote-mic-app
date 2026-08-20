# Mac 预览版权限身份连续性测试

## 适用版本或分支

- 分支：`codex/onboarding-clickable-permissions` 或后续集成候选
- 目标：由受保护 `macOS Signed Release Packages` 工作流生成并发布到私有 Draft 或公开 Pre-release 的 Developer ID 签名公证包

## 测试前准备

1. 一台已安装旧版无线麦SayAll.app且输入监控、辅助功能均已开启的 Mac。
2. 记录旧 App 路径、版本、`codesign -dv --verbose=4` TeamIdentifier 和 `codesign -dr -` designated requirement。
3. 从私有 Draft 或公开 Pre-release 下载对应 commit 的正确架构 DMG；不要使用本地构建或 `macOS Preview Candidate` 的 ad-hoc CI Artifact 代替。

## 用例一：旧路径升级

1. 确认旧 App 位于 `/Applications/Remote Mic.app`，按键映射可正常执行。
2. 不删除系统设置中的权限条目，直接运行候选 DMG 中的安装器。
3. 启动无线麦SayAll.app并进入“权限与隐私”。
4. 按一次普通遥控器按键并执行一个需要辅助功能的映射。

预期：

- App 安装为 `/Applications/SayAll.app`。
- 输入监控和辅助功能继续显示“已开启”，不要求删除旧条目。
- 普通按键和映射动作均可用。
- 运行日志显示 `HID PERMISSIONS input=true accessibility=true`。

失败判定：任一权限变成待开启、必须清理旧条目、按键监听未启动，或代码签名 Team ID 与旧正式版不同。

## 用例一 A：升级后权限没有延续

1. 使用正式签名旧版完成 Onboarding，然后通过真实更新路径升级候选。
2. 在升级首次启动前，从系统设置撤销蓝牙、输入监控或辅助功能中的一项，用来稳定模拟权限未延续。
3. 启动新版本，确认 App 打开设置窗口后直接显示“权限与隐私”，不先显示连接页，也不要求重跑完整 Onboarding。
4. 确认被撤销项显示待开启，其他项继续显示真实状态；补授权后返回 App。
5. 确认页面刷新并恢复现有按键映射，不清除连接、音频设备或其他设置。

预期：只有“已完成 Onboarding + 刚完成更新 + 任一权限缺失”触发定向修复。权限全部正常、普通启动和新用户 Onboarding 不改变。日志出现一次 `UPDATE PERMISSION_REPAIR`，三个字段与页面状态一致。

失败判定：权限缺失仍打开连接页、权限全部正常却误跳权限页、老用户被强迫重跑完整向导、点击或访问权限页就伪造授权成功，或补授权后现有配置丢失。

## 用例二：同路径覆盖更新

1. 在已安装候选的基础上再次安装同一签名身份的更高 Build 候选。
2. 重启 App并执行普通按键与语音基线。

预期：权限保持开启，按键与语音行为不变。

## 用例三：全新安装

1. 在没有无线麦权限历史的测试账户安装候选。
2. 按正常流程请求输入监控和辅助功能。

预期：系统只显示当前无线麦SayAll.app条目；授权后权限页隐藏重复“请求权限”按钮。

## 稳定功能回归

- 蓝牙语音可开始、持续传输并停止。
- 普通 OK、方向键映射正常。
- 系统设置中不存在相同 Bundle ID 的异常重复运行副本。
- DMG、App、PKG 均通过签名、公证和 staple 校验。

## 日志收集

- App：`~/Library/Logs/RemoteMic/runtime.log`
- Installer：记录失败北京时间并截取 `/var/log/install.log` 对应时间段；同时记录下载资产完整文件名、Mac 架构、安装前 `/Applications/Remote Mic.app`、`/Applications/无线麦.app`、`/Applications/SayAll.app` 的存在状态与版本。不要手动删除旧 App 后才开始收集。
- 签名：保存 `codesign -dv --verbose=4` 与 `codesign -dr -` 输出，不上传证书私钥或任何凭据。
- 记录安装前后北京时间，并在分析时换算日志 UTC。

## 验证边界

静态测试只能证明候选 CI 不接触签名凭据、可分发包必须经过受保护 Developer ID 签名公证流程，以及权限缺失时会定向打开修复页；只有上述同机真实升级可以证明 macOS TCC 权限是否连续。自动化不能替代系统设置、真实遥控器、Installer 日志和真实签名 Artifact。
