# 可选诊断公钥字段误判

## 复现与日志

签名 smoke [37202916024](https://github.com/HD838A/remote-mic-app/actions/runs/37202916024) 在 App 校验阶段失败。
两架构已完成编译和签名，尚未完成公证。
错误为 `SayAllDiagnosticPublicKey must encode a 32-byte Curve25519 public key`。
普通构建允许省略该字段，预期校验通过。

## 根因与修复

`plutil` 在字段缺失时可向 stdout 写错误文字并返回失败。
旧读取代码保留了错误文字，并将其当作公钥。
先通过退出状态判断字段存在，再按 string 类型读取。
类型错误、非法值和必需字段缺失仍拒绝通过。
`-type` 和 `-expect` 从 macOS 12 起可用，覆盖当前最低系统。
本次不更换密钥，不修改 App 功能或发布门禁。

## 验证

回归执行生产脚本中的实际校验块，并模拟 stdout 错误。
修复前，可选缺失与必需缺失两个用例失败。
修复后，六个用例及全部 24 项 BuildSigningTests 通过。

```sh
RELEASE_VARIANT=intel swift test --disable-keychain --filter BuildSigningTests
```

用例覆盖可选缺失、必需缺失、非法 Base64、有效公钥的两种模式及错误 plist 类型。
自动化不替代 Developer ID 签名、公证、安装或真实设备验收。
完整发布结果单独记录。
