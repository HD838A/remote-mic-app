# 未授权模型初始化导致 Keychain 并行回归等待

## 复现

在 AI 整理首次接入当前预览分支后运行：

```bash
swift test --jobs 4
```

单独运行 Early Access 与 AI 用例可以通过，但完整测试并行执行时长时间无进展。可重复边界是：多个稳定功能测试同时初始化 `BridgeAppModel`，即使没有 Early Access 资格，也会读取 DeepSeek Keychain；同时 Early Access 测试正在创建独立测试 Keychain 项。

## 日志与现场证据

对等待中的测试进程采样，两个并发栈分别停在：

- `BridgeAppModel.init → DeepSeekCredentialStore.loadAPIKey → SecItemCopyMatching`
- `EarlyAccessController.redeem → EarlyAccessCredentialStore.createDeviceIDIfNeeded → SecItemAdd`

两者都在 macOS Security 服务的 Keychain 加解密 IPC 中等待。没有业务测试断言失败，也没有蓝牙、音频或 DeepSeek 网络请求。

## 根因

`BridgeAppModel` 初始化时无条件加载 DeepSeek API Key 和术语文件。该行为既违反“普通未授权用户不触碰 AI 本地数据”的隔离目标，也让大量与 AI 无关的并行测试进入旧式应用专用 Keychain 路径，引发系统 Security 服务争用。

## 修复

- 未获得有效 Early Access 资格时，不加载 DeepSeek Key 或术语文件。
- 资格变为有效时再延迟加载 AI Keychain 和术语。
- 资格失效只关闭和取消 AI 运行，不删除已保存 Key 或术语。
- `ProgrammingTermStore` 在模型中改为按资格延迟创建，避免未授权初始化读取文件。

## 验证

```bash
swift test --jobs 4
```

结果：232 项测试、30 个 Suite 全部通过，耗时约 0.25 秒；不再出现 Security Keychain 等待。

Early Access 四态用例同时确认：资格缺失时关闭、授权后本地开关仍关闭、主动开启且配置 Key 后可运行、撤销后立即关闭且 Key 仍保留。

## 自动化与真实环境边界

该验证证明未授权模型初始化不再读取 AI Keychain，并消除了进程内并行回归等待。它不替代真实签名 App 的系统 Keychain 访问、真实邀请码生命周期、RC003、豆包输入法或 DeepSeek 请求验收。
