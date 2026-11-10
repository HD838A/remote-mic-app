# publication 在公开前完成远端校验

## 证据与根因

原入口在创建 Release 时即公开为 Pre-release，然后才上传和验证集合、摘要与下载字节。此前实际发布因数量和 CDN 契约失败，证明公开状态可能先于完整校验。现有测试只摘取数量判断，没有执行整个状态转换。

## 修复与回归

首次创建 Draft，完整上传和 digest 校验后，从认证 asset API 下载每项并与 staging 原件比较。全部通过后公开同一 Release，继续 GitHub、CDN、通道和 stable latest 验证。失败及可捕获终止信号收回 Draft，API 回读确认。既有公开候选重试先进入 Draft，保留 Release ID、资产 ID 和内容。元数据不一致时停止且保留原文。

`python3 scripts/test-private-platform.py PublicationFlowTests` 完整执行生产入口，覆盖成功、部分上传、数量、摘要、认证字节、公开 CDN 字节、终止、旧 manifest 和重试身份。fixture 替代远端 API、下载、stage 恢复与 UI 证明，不替代真实签名或真实 Sparkle UI。未对已有真实 Release 执行本次故障实验。回收依赖远端 API 和退出处理器可以执行；失败告警须立即处理，已缓存公开字节无法撤销。

公开验证共用 300 秒总预算，并受脚本启动后 600 秒软截止时间限制。避免逐项重试累计超过 workflow 的 20 分钟硬超时。超时回归用 1 秒 fixture 预算，断言同一 Release 被收回 Draft。
