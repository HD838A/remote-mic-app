# 遥控器连接且空闲时音频引擎自我维持的重绑循环

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机观测待验收
- 影响范围：选择了虚拟音频设备、且遥控器保持连接但长时间无语音的常驻用户
- 功能点：`AVAudioEngineConfigurationChange` 通知的处理与音频恢复
- 简单描述：App 在「遥控器已连接、无语音」的常驻状态下陷入「重绑 → 引擎配置变化 → 判定需要恢复 → 重绑」的闭环，约每 1.2 秒一圈，永不停止。不影响听到的声音，但持续耗 CPU，并让日志高速轮转、把真正有用的历史冲掉。

## 复现与现场证据

无需操作，App 常驻即可。现场（基于 v1.8.25 的构建，选中输出为 `MiRemoteV 2ch`）实测每分钟 48 次 `AUDIO RECOVERY begin`，成串爆发、间歇停歇，日志文件 20 分钟轮转一份 4MB。一个完整周期：

```text
AUDIO RECOVERY begin id=2028 reason=engine_configuration_change ... bound_to_selected=true
AUDIO REBIND begin reason=recovery_engine_configuration_change
AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=88}
AUDIO READY target={name=MiRemoteV 2ch id=88}
AUDIO REBIND finished success=true
AUDIO RECOVERY completed id=2028
AUDIO ENGINE configuration_changed generation=4013     ← 重绑自己造成的
AUDIO RECOVERY scheduled id=2029 reason=engine_configuration_change   ← 于是再排一次
```

全程 `engine_running=false`（没有播放），且 `bound_to_selected=true`（设备一直正确绑定）。`AUDIO READY` 之后**紧跟** `configuration_changed`，每个周期都如此；`generation` 每圈 +2，正好等于观察者重建的两次计数——闭环成立。

## 根因

抑制这个循环的门禁要求「引擎正在运行」（上游现状为 `VirtualAudioHealthPolicy.isConfigurationHealthy` 中的 `engineRunning && playerPlaying`）。而循环恰好发生在引擎空闲时——也就是自造配置变化会发生、且完全没有东西需要恢复的时候。于是抑制在最该生效的场景下不可用，每一次自己造成的变化都被当成真实硬件变化去恢复，而恢复动作又造成下一次变化。

判据本身拿错了：`engine.isRunning` 证明的是「音频正在流动」，不是「绑定仍然正确」。`currentOutputDevice()` 读的才是「还绑着」的直接判据，且不要求引擎在跑。

**上游已有缓解的边界**：`scheduleAudioRecovery` 的 `shouldKeepVirtualAudioActive` 门禁在「无连接、无语音」时忽略恢复（配合空闲释放引擎），覆盖了**遥控器断开**的空闲场景。但遥控器保持连接（`readyBluetoothBridgeCount > 0`）时虚拟音频视为应保持活跃，门禁放行——这正是用户最常处的常驻状态，循环在该状态下仍然成立。`configureVirtualAudioOutput` 也不判绑定、无条件重绑。

## 修复

抽出 `AudioEngineConfigurationChangePolicy.needsRecovery(selectedDeviceID:currentOutputDeviceID:)`，只比较这两个设备 id：相等即忽略，任一为 nil 则朝「需要恢复」方向失败（引擎没有输出设备、或尚未选定，都不是绑定正常的证据）。配置变化通知回调改走该策略，判据不再依赖引擎是否运行。

`isConfigurationHealthy` 保留原义，仍服务于恢复路径上的诊断与 `default_system_output` 抑制，本次只替换通知回调这一处判据。

## 验证

自动化（5 项新测试）：

- 绑定未变必须忽略（回归本体）；
- 绑定被改必须恢复（正向对照，否则「永不恢复」也能通过）；
- 任一侧未知必须恢复；
- 判定不得依赖引擎是否运行（这是签名级别的性质：策略根本拿不到 `engine.isRunning`）；
- 按现场日志形态回放整个周期必须收敛为 0 次重绑。

`swift test` 全量通过；`scripts/test.sh`、`scripts/check-repository-boundaries.sh` 通过。

真机对比验证（此前在同形态代码上做过，本次上游版本待复测）：循环正在发生的机器上对比两个版本各 3 分钟——修复前约 144 次 `AUDIO RECOVERY begin`，修复后 0 次且出现 `configuration_ignored reason=still_bound`。按 `Testing/AudioConfigurationChangeRecovery.md` 复测，并补做真实拔插与语音会话中配置变化两项。

## 未覆盖

- 通知回调本身的接线（`observeConfigurationChanges` 私有且需要真实 `AVAudioEngine`）；
- 真实拔插外接音频设备时恢复是否仍然及时；
- 语音会话进行中发生配置变化的行为，与 `2026-09-05-voice-session-wedges-when-audio-reconfigures-mid-drain` 场景的交互；
- 长时间运行后循环是否会以其他形式回来。
