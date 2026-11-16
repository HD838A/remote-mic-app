# 历史设备持续盲连且缺少手动恢复入口

## 证据与边界

- PR #1072 描述：RC003 在线时，离线 RC001 档案仍每约一分钟连接超时。17 次超时和 26 次调度来自原 PR，本次没有取得原始现场日志，未独立复算。
- 静态证据：原 `startBluetoothConnections()` 为每个历史 Bluetooth identifier 建桥；`BluetoothReconnectPolicy` 只有 60 秒间隔上限，没有次数或总时限；连接页过滤离线卡片。
- 可重复实验：从开发基线原样提取 `BluetoothReconnectPolicy`，连续调用 100 次 `nextAutomaticDelay`，输出 `failure_count=100 delay=60 next_attempt_still_scheduled=true`。实验在仓库外执行，无产品修改。
- 因而可以确认“旧档案可永久调度”的代码根因；不能据此确认任意具体设备的现场超时原因。

## 修复

- 历史档案不逐台盲连；共享发现只报告候选，目标桥独立连接，坏候选不占住发现过程。
- 每台设备保留独立恢复预算，桥替换、重复广播或前台切换不重置耗尽状态；自动三次/60 秒、手动一次/30 秒，短暂 Ready 和周期掉线另受限制。
- 系统休眠期间的已连接设备断开，等真实恢复后再开启其有限窗口；已耗尽的设备仍保持暂停。发现管理器在权限阻断时保留状态观察，目标连接停止。
- 连接页新增“连接过的设备”，支持目标连接、取消和有冷却的重试；全部断开默认展开，不保留重复查看按钮。
- 新增窗口、尝试关联和终态日志；拒绝候选聚合。没有设备身份的发现状态，不能被当作当前语音设备的断开，也不能结束另一台的长录音。

## 验证命令与结果

- `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain -j 4`：结果记录于 PR 当前 Head；新增预算、睡眠、权限观察、改名和日志聚合回归。
- `scripts/verify-localizations.sh`、`scripts/verify-repository-governance.sh origin/main`、`git diff --check`。
- 生产 UI 证据通过 `SettingsScreenshotRenderer` 的隔离夹具取得，索引与 Commit 见 PR。
- 完整实机步骤见 [测试手册](../Testing/RemoteConnectionRecovery.md)。

## 尚未完成

真实 RC001/RC003 的返回时机、CoreBluetooth 回调、首次语音、首尾音、多设备隔离、权限恢复和整夜睡眠尚未验收。自动化和生产视图截图不能替代这些结果；当前为待真机验收的候选；用户授权自动化通过后合入，由用户随后完成真机测试，不据此发布。
