# Intel Sparkle appcast 缺少本地化更新说明

## 复现

1. 为 Intel lane 生成 `Remote-Mic-<version>-Intel.zip`。
2. 同目录仅放置 `Remote-Mic-<version>.en.txt` 和 `Remote-Mic-<version>.zh.txt`。
3. 使用 Sparkle 2.9.4 `generate_appcast` 生成 `appcast-intel.xml`。

错误行为：appcast 能生成 enclosure，但没有 `sparkle:releaseNotesLink`，发布脚本随后因找不到本地化更新说明 URL 而失败。

正常行为：Intel appcast 同时包含英文与中文更新说明链接，文件名与 Intel ZIP lane 隔离。

## 日志结论

受保护发布 run `31621815921` 中，两种架构的 App、安装/卸载 PKG 和 DMG 均已完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 与项目校验。失败发生在：

```text
Wrote 1 new update, updated 0 existing updates, and removed 0 old updates in appcast-intel.xml
Process completed with exit code 1
```

使用一次性测试 Sparkle 密钥复现后确认，Sparkle 只会把与 archive 同 basename 的 `.en.txt` / `.zh.txt` 识别为更新说明。

## 根因

Intel ZIP 使用 `Remote-Mic-<version>-Intel.zip`，但 `notarize-release.sh` 为两个架构都生成不带 lane 后缀的 `Remote-Mic-<version>.en.txt` 和 `.zh.txt`。因此 Intel appcast 无法关联说明文件。

## 修复

- 更新说明文件使用与 ZIP 相同的 `RELEASE_ASSET_SUFFIX`。
- 发布脚本分别校验并上传 Apple Silicon 与 Intel 的中英文说明。
- provenance 与 Release 守卫的预期 payload 数量从 14 调整为 16。

## 验证边界

使用一次性测试密钥验证 Sparkle basename 关联规则；生产签名、公证、Sparkle EdDSA 和公开资产仍由重新运行的受保护候选流水线验证。
