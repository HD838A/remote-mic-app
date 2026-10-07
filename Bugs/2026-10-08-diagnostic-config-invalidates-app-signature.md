# 诊断配置注入后 App 签名失效

## 错误证据

预览版 `v2.0.0` 的受保护 staging 在两种架构的 `app-verify-pre-notary` 阶段失败。两条日志都报告：

```text
invalid Info.plist (plist or signature have been modified)
```

失败发生在 Apple 公证前，没有生成公开资产。

## 根因

私有脚本 `inject-private-diagnostics-config.sh` 在 `build-app.sh` 完成 Developer ID 签名后，把 `REMOTE_MIC_SENTRY_DSN` 写入 App 的 `Contents/Info.plist`。签名资源封印因此失效。

## 修复

注入 Sentry 配置后，使用同一个 Developer ID Application 身份重新签名主 App，再运行现有 `verify-app.sh`。签名、公证和公开发布流程保持原有顺序。

## 验证边界

- 自动化：发布签名测试检查“注入 → 重新签名 → 预公证验证”的顺序。
- 受保护 staging：修复合入 `main` 后重新执行双架构签名、公证、staple 和制品校验。
- 真实 Sparkle UI 和 Sentry 发送验证在新的 staging 制品生成后执行。
