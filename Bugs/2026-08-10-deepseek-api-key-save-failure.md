# DeepSeek API Key 保存失败

## 复现

- 环境：macOS，本地 `1.8.1 (62)` Ad Hoc 体验包。
- 触发条件：打开“AI 整理”，输入任意非空测试 Key，点击“保存 Key”。
- 错误行为：输入框被清空，状态仍为“Key 未配置”，无法继续测试连接。
- 同时复现：输入框获得焦点后按 `Command-V`，剪贴板文字没有进入输入框，保存按钮仍禁用。
- 正常边界：Key 应写入本机钥匙串；只有保存成功后才清空输入框并允许测试连接。

## 日志结论

失败发生在 2026-08-10 08:53:05：

```text
RemoteMic (Security) SecItemUpdate
RemoteMic (Security) SecItemAdd
securityd CSSMERR_CSP_INVALID_DATA
RemoteMic CSSMERR_CSP_OPERATION_AUTH_DENIED
```

同一用户会话下，独立 Swift 探针对旧登录钥匙串执行 `SecItemAdd` 返回 `-25293`；`security show-keychain-info` 也返回相同认证失败。说明 DeepSeek 请求尚未发生，失败点是旧登录钥匙串不可写。

## 根因

`DeepSeekCredentialStore` 默认写入旧登录钥匙串，本机登录钥匙串当前不可写。Data Protection Keychain 需要受限 access group 和匹配的 Developer ID provisioning profile；现有只读签名仓库没有该 profile，直接签入受限权限会被 AMFI 拒绝启动。设置页还会在保存失败时无条件清空 Key 草稿，导致用户必须重新输入。

应用由 AppKit 手工启动，但没有创建标准“编辑”主菜单，因此 `Command-V` 没有 Paste 命令可以沿第一响应者链路发送给 `SecureField`。

## 修复

- 优先使用 Data Protection Keychain；没有共享 access group 权限时，回退到 `Application Support/Remote Mic/RemoteMic.keychain-db` 应用专用 Keychain。
- 应用专用 Keychain 仍由 macOS Security.framework 创建、解锁和读写，文件权限固定为 `0600`，Key 条目 ACL 只信任创建它的 Remote Mic App；不把 Key 写入 UserDefaults、日志或明文配置，也不依赖当前已损坏的登录钥匙串。
- 保存失败时保留输入框内容；仅保存成功后清空。
- 恢复标准编辑菜单及撤销、剪切、复制、粘贴和全选快捷键。
- 保存后输入框只显示 Key 前四位和后四位，中间使用固定遮罩；不把完整 Key加载到输入框。

## 验证

已执行完整自动化测试：

```text
swift test --jobs 4
162 tests passed
```

已从不存在应用专用 Keychain 文件的首次运行状态重新执行原始 UI 复现：

- `Command-V` 可以把剪贴板中的测试 Key 粘贴到输入框。
- 点击“保存 Key”成功，状态变为“Key 已配置”。
- 保存后输入框只显示 Key 前四位和后四位，中间内容不回显。
- 退出并重新启动 App 后，仍能读取已保存状态和遮罩预览。
- 点击“删除 Key”成功，状态恢复为“Key 未配置”。
- 所有测试 Key 均已通过 UI 删除。

## 验证边界

- 自动化与本机 UI 只能证明 Keychain 保存链路、构建和设置页状态恢复正常。
- 真实 DeepSeek Key、豆包输入法、遥控器语音和完整 AI 整理链路仍需人工验收。
