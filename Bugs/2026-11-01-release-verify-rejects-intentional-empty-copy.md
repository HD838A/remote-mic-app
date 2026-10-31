---
title: 发布校验拒绝有意留空的英文文案，导致无法打出任何正式包
template: doc
---
## 状态与范围
时间：2026-11-01。状态：已修复，等待下一次完整签名打包复验。
范围：`scripts/verify-app.sh` 的本地化完整性校验，与 `Resources/en.lproj/Localizable.strings` 的可空文案约定。不涉及产品界面、统计口径、签名、公证或发布渠道。

## 复现与边界
在 `origin/main` 的 `9190672d` 上执行项目原生打包入口 `scripts/notarize-release.sh --all`。
两个架构的 App 构建都成功，随后在 `app-verify-pre-notary` 阶段失败，Intel lane 退出码 1：

```
dist/intel/SayAll.app/Contents/Resources/en.lproj has an empty value for statistics.metric.count_unit
```

Apple Silicon lane 在并行取消前处于同一阶段，单架构单独执行 `scripts/verify-app.sh dist/SayAll.app` 也以相同报错退出 1。
`macOS CI` 在该提交上是通过的：CI 只运行 `swift test` 和 Release 构建，不执行 `verify-app.sh`，所以该缺陷不会被常规 CI 暴露。
受影响的是所有正式签名包（Preview、Stable、私有 Draft），不是某一个渠道或某一台机器。

## 根因与最小修复
`a4e04b48`（2026-10-31，`fix(mac): polish profile English copy and drop the count unit`）把英文计数单位改成空串，让英文界面整段省略“次 / times”这个单位，并在 `Tests/RemoteMicTests/LocalizationTests.swift` 里加了 `intentionallyEmptyKeys = ["statistics.metric.count_unit"]` 白名单。
同一个约定没有同步到发布校验器：`scripts/verify-app.sh` 内嵌的 Ruby 校验对任何空值直接 `abort`，于是产品意图与发布门禁互斥。
最小修复是在该校验器内引入同一份白名单：只有白名单键允许为空，其余空值照旧失败，并跳过该键的格式和受限词检查，避免空值继续参与占位符比较。

## 验证与边界
修复前，用主线脚本验证本次构建的 App：`verify-app.sh dist/SayAll.app` 以 `en.lproj has an empty value for statistics.metric.count_unit` 退出 1。
修复后，同一命令对 Apple Silicon 与 Intel 两个 App 都返回 `APP VERIFY PASS`。
反向对照：把 `statistics.ranking.title` 在 en 副本中改成空串后重新校验，仍然以 `en.lproj has an empty value for statistics.ranking.title` 退出 1，说明门禁没有被整体放宽。
`zsh -n scripts/verify-app.sh` 通过。
本次验证直接使用打包流程刚产出的签名 App，不是模拟夹具；但它只证明静态校验通过，不证明安装、公证票据、Gatekeeper、真实设备或真实语音链路，这些仍由打包流程的后续阶段与现场验收覆盖。
