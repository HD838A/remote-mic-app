# 私有 Draft 缺少诊断日志公钥

## 复现

- 版本：SayAll 1.10.0（Build 229）。
- 启动 Developer ID 签名、公证并 staple 的私有 Draft 安装包，执行设置切换和遥控器操作。
- `~/Library/Logs/RemoteMic/` 没有生成本次会话的 `.rmlog`。

## 日志与现场证据

- 统一日志持续出现 `encryption_public_key_missing` 和 `encrypted_log_write_failed`。
- 最终 `/Applications/SayAll.app/Contents/Info.plist` 不包含 `SayAllDiagnosticPublicKey`。
- `scripts/build-app.sh` 只有在 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64` 非空时才注入字段，Build 229 的发布环境没有提供该变量。
- 用户确认没有开启“语音键模拟 Fn 点按”，因此固定的 150ms Fn 点按准备路径不适用于本次语音迟钝现场。

## 根因

私有 Draft 构建把诊断公钥作为可选输入，最终 App 校验也不检查该字段；公钥缺失时签名、公证和上传仍然成功，但运行时加密日志按安全设计闭锁。

## 修复

- `scripts/build-app.sh` 增加 `REQUIRE_DIAGNOSTIC_PUBLIC_KEY=1` 门禁；缺失、无效 Base64 或解码后不是 32 字节的公钥均停止构建。
- `scripts/verify-app.sh` 对最终 App 执行同样的存在性和长度校验，防止中间打包步骤丢失字段。
- 默认值保持为 `0`，公开源码和无受控密钥的开发构建继续验证既有“缺少公钥时不回退明文”的行为。

## 验证

- 自动化覆盖构建和最终 App 校验脚本必须保留诊断公钥门禁。
- 私有 Draft 构建必须显式传入 `REQUIRE_DIAGNOSTIC_PUBLIC_KEY=1` 和受控环境提供的 `SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64`。
- `BuildSigningTests` 23 项通过；强制模式下缺失公钥和解码后不足 32 字节的公钥均在构建前 fail closed。
- 使用已经先合入私有 `GetSayAll/sayall-membership-ops` 主线的公钥构建本地主线 Release App，`verify-app.sh` 通过，最终 `Info.plist` 中公钥解码长度为 32 字节。
- 启动该候选后生成权限为 `0600`、文件头为 `RMLG2` 的新会话日志。使用私有仓库远端 `main` 的 age 密文取得匹配私钥，成功解密 88 条记录；验证过程只输出记录数与版本元数据，没有输出日志正文或密钥。
- 当前验证证明本地主线候选的日志链路可用；尚未重打 Developer ID 签名、公证并上传的私有 Draft，也未重新执行遥控器语音按压时间线。

## 验证边界

- 本修复只恢复日志可用性门禁，不修改语音键、音频、Siri Remote、会员或键位方案行为。
- 本次用户反馈中的语音延迟唯一根因仍需新包日志还原硬件按下、流开始、首个 PCM、Fn 注入和松键时间线。
