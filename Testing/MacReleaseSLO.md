# macOS 发布 30 分钟目标测试手册

## 目标与边界

- Preview 和 Stable promotion 都从 T_ready 起使用 30 分钟纯发布目标。
- T_request 是用户首次发出本次发布指令的时间，统计完整用户等待；T_ready 是代码、main CI、依赖 pin、版本、Build 和必要发布输入全部就绪并冻结的时间。
- 30 分钟是发布目标和报告指标，不允许跳过签名、公证、staple、真实 Sparkle UI 或下载字节验证。
- 不再使用候选分支、编号 rerun、qualification、watchdog 或 ledger 状态机。失败要立即分类并继续可安全的同 SHA 恢复。

## 测试前准备

1. 记录 UTC 的 T_request、T_ready、sourceCommit、版本、Build。
2. 运行 scripts/verify-release-ready-main-ci.sh 和 scripts/verify-release-dependency-pins.sh。
3. 确认 stable latest 是 v1.8.3。
4. 使用独立目录保存阶段开始/结束时间、Run URL 和验证输出。

## 用例 1：Preview 计时

1. 从 T_ready 开始 dispatch scripts/stage-macos-preview.sh preview。
2. 记录 staging、真实 UI、publication 和公开字节验证的开始/结束时间。
3. 在完成后计算 T_ready 到公开验证完成的秒数。

预期：总纯发布时间不超过 1800 秒；同时报告 T_request 到完成的总时间和各阶段耗时。

失败判定：只报告 CI 时间、重试后重置 T_ready、将等待隐藏为“没有耗时”，或为了达标跳过安全门禁。

## 用例 2：Stable 计时

1. 明确指定一个现有、已验证且 Tag Commit 已进入 origin/main 的 Pre-release。
2. 从 T_ready dispatch mac-stable-promote.yml。
3. 记录验证和 gh release edit 的开始/结束时间。

预期：只执行 provenance/资产复验和分类变更，纯发布时间不超过 1800 秒；不发生任何构建、签名或上传。

## 用例 3：失败分类

分别模拟以下情形：

- main CI 或版本输入未就绪；
- Runner、Environment、Apple、GitHub 或网络故障；
- 真实 UI 验收失败；
- 公共资产摘要或 CDN 字节不一致；
- Stable Tag 未进入 main。

预期：报告中明确区分“发布未就绪”“基础设施/外部服务”“UI 验收”“公开交付验证”和“晋升资格”失败。基础设施失败复用同一 SHA、版本、Build 和 artifact，不创建新版本。

## 稳定功能回归

- 同 SHA 重试不改变 T_request、T_ready、版本、Build 或 artifact。
- Preview 期间 releases/latest 始终为 v1.8.3。
- Stable 只改变 Release 分类，不改变资产摘要。
- 版本选择和首次 Tag 创建前的 11 个 CDN 固定路径检查只有 404 才通过；Stable 还必须复验 exact staging Run/attempt/artifact 证据。
- 达到 30 分钟目标不是取消或降级的理由；若超时，停止突变并给出明确阻断。

## 日志收集

保存时间戳、Run ID/URL、阶段状态、资产摘要和失败类别；不保存 Apple 凭据、Token、密码或私钥。真实图形会话、实体硬件和第三方 App 未执行时必须明确标记。
