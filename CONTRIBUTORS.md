# 贡献者

本文件记录**被本仓库采纳或依赖其成果**的外部贡献者。它是归属记录，不是现行产品规范，也不替代 [`LICENSE.md`](LICENSE.md)、[`COPYRIGHT.md`](COPYRIGHT.md) 和 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 中的许可信息。

维护者名单不在此处；本文件只记录本仓库外部作者的可核对贡献。

## 记录规则

- 只在贡献已被本仓库采纳、或在修复与决策中被实际引用时记录，不记录仅提交但未被采纳的内容。
- 每条记录必须给出可核对的来源（Issue 或 PR 编号）和具体的贡献内容，不写笼统的「感谢贡献」。
- 引用他人的 Issue 报告、最小实验或 PR 时，必须同步在本文件和对应 `Bugs/` 记录中署名。

## 当前记录

| 贡献者 | 贡献 | 来源 |
| --- | --- | --- |
| [@peterhon168](https://github.com/peterhon168) | 定位后台长期运行后 event tap 累积的根因（`KeyboardEventSuppressor.stop()` 未对底层 `CFMachPort` 调用 `CFMachPortInvalidate`），并给出最小对照实验：100 次 create/stop 循环在不调用 invalidate 时残留 100 个 tap、显式调用后残留 0 个。该根因与实验是本仓库修复的直接依据。 | [#476](https://github.com/HD838A/remote-mic-app/issues/476) |
| [@btiger](https://github.com/btiger) | 提交部分范围的修复 PR（补齐 `KeyboardEventSuppressor.stop()` 的 invalidate），并在 #476 补充同环境独立佐证：本机 `runtime.log` 中单实例连续运行 4.96 天、`HID START` 1,039 次，与 #476 实测的 2,378 个残留 tap 对账（偏差约 13%）。该日志统计已并入 [`Bugs/2026-09-27-event-tap-port-not-invalidated.md`](Bugs/2026-09-27-event-tap-port-not-invalidated.md)。 | [#493](https://github.com/HD838A/remote-mic-app/pull/493)、[#476 评论](https://github.com/HD838A/remote-mic-app/issues/476#issuecomment-5827054801) |
| [@L33Z22L11](https://github.com/L33Z22L11) | 在 `SayAll 1.9.21 (174)` / `macOS 26.6.2` 上独立复现同一现象，后台运行约 4 天后实测累积 **1,872 个已禁用 event tap**、重启后仅剩 1 个。该证据把缺陷范围从 macOS 27 扩展到 macOS 26，是本仓库不把它判定为 macOS 27 回归的依据。 | [#446 评论](https://github.com/HD838A/remote-mic-app/issues/446#issuecomment-5805743571) |
| [@idootop](https://github.com/idootop) | 最早以「长时间后台运行 + 多次开合屏幕后触控板手势极其卡顿、退出无线麦即恢复」的形式报告该症状，为问题提供了首个用户侧可复现描述。 | [#446](https://github.com/HD838A/remote-mic-app/issues/446) |
| [@leafney](https://github.com/leafney) | 最早的同类现象报告（长时间运行后系统卡顿、关闭无线麦后恢复）。 | [#337](https://github.com/HD838A/remote-mic-app/issues/337) |
