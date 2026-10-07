# 诊断配置重新签名阶段缺少默认超时

## 错误证据

预览版 `v2.0.0` 的第二次受保护 staging 已通过源码和私有资源构建，但在诊断配置注入后进入重新签名阶段时失败：

```text
RELEASE_CODESIGN_TIMEOUT_SECONDS: parameter not set
```

## 根因

重新签名步骤引用了 `RELEASE_CODESIGN_TIMEOUT_SECONDS`，脚本启用 `set -u`，但没有为该变量设置默认值。

## 修复

为签名阶段设置默认 45 秒预算，并在构建签名测试中检查该默认值。

## 验证边界

- 自动化：定向 `BuildSigningTests` 检查脚本顺序和默认超时。
- 受保护 staging：修复合入 `main` 后重新执行双架构签名、公证、staple 和制品校验。
