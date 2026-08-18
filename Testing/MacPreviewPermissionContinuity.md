# Mac 预览版权限身份连续性测试

## 适用版本或分支

- 分支：`fix/bug-1.9.0-test-permission-history-hid-20260819`
- 目标：由 `macOS Preview Candidate` 受保护工作流生成的 Developer ID 签名候选

## 测试前准备

1. 一台已安装旧版无线麦SayAll.app且输入监控、辅助功能均已开启的 Mac。
2. 记录旧 App 路径、版本、`codesign -dv --verbose=4` TeamIdentifier 和 `codesign -dr -` designated requirement。
3. 从对应 commit 的 Actions Artifact 下载正确架构 DMG；不要使用本地 ad-hoc 构建代替。

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
- 签名：保存 `codesign -dv --verbose=4` 与 `codesign -dr -` 输出，不上传证书私钥或任何凭据。
- 记录安装前后北京时间，并在分析时换算日志 UTC。

## 验证边界

静态测试只能证明工作流要求受保护 Developer ID 身份；只有上述同机真实升级可以证明 macOS TCC 权限是否连续。自动化不能替代系统设置、真实遥控器和真实签名 Artifact。
