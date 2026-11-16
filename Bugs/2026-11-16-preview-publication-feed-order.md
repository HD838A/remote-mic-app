# Preview publication 在 feed 同步前要求 preview channel 已更新

## 状态

已修复并验证：publication run `43763008826` 成功发布 `v2.0.3` Pre-release，preview feed 为 2.0.3，stable latest/feed 保持 1.9.21。

## 影响范围

- macOS Preview publication workflow，资产已上传后的公开验证阶段。
- 2.0.3 staging、签名、公证、staple、Sparkle 真实 UI 验收和下载字节已通过。
- 失败时 workflow 按设计把候选保留为 Draft；stable latest 仍为 `v1.9.21`。

## 错误证据

`macOS Preview Publication` run `43760297537`：

- 第一次尝试：Draft 资产认证读取通过，切换公开后 GitHub 下载 URL 在约 8 秒内仍返回 404；脚本重试 4 次 × 2 秒后失败，并把候选回退为 Draft。
- 第二次尝试：Draft 资产与公开 GitHub 文件验证通过，随后在 preview channel 校验失败：

```text
Cloudflare preview channel did not resolve to the expected appcast: appcast.xml
```

此时 `download.sayall.app/mac/channels/preview/appcast.xml` 仍是旧的 `1.9.20`。workflow 的 feed 同步步骤排在 `publish-preview-release.sh` 之后，而脚本在同步前要求 preview channel 已等于新的 `appcast.xml`。

## 根因

1. `publish-preview-release.sh` 在 workflow 的 feed 同步步骤之前校验 preview channel，顺序自相矛盾。
2. `fetch_public_asset` 只重试 4 次、每次间隔 2 秒，短于 GitHub Release 公开后资产 URL 的实际传播时间。

## 修复

- 移除脚本在 feed 同步前的 preview channel 校验；preview channel 由 workflow 的 `sync-update-feeds.mjs` 步骤更新并验证。
- 保留 stable channel 校验和 stable latest 不变校验。
- 将公开资产下载重试延长到最多 20 次、每次 6 秒，仍受既有 `public_verification_deadline` 约束。
- publication workflow 增加 `if: failure()` 回退步骤：发布或 feed 同步失败时把候选重新设为 Draft，并读取确认。

## 验证

- PR CI 与合并后 main CI 通过。
- 用同一 2.0.3 attestation 重跑 publication，run `43763008826` 完成公开资产验证、feed 同步和最终核对。
- `v2.0.3` Release 为 Pre-release 且非 Draft；preview 与 Intel preview feed 均为 2.0.3；stable feed 与 `releases/latest` 保持 `v1.9.21`。

## 验证边界

修复不改变已 staging 的 2.0.3 资产、签名、公证、UI attestation 或 stable feed。它只调整 publication 的校验顺序、重试窗口和失败回退；若 feed 同步失败，候选仍保持 Draft。
