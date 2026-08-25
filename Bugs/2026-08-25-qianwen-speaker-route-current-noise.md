# 千问语音输出误选 Mac 扬声器产生电流声

- 时间：2026-08-25
- 状态：已修复，自动化与原路径复验通过，等待最终听感确认
- 影响范围：开启千问兼容模式后，语音输出设备被改成实体扬声器
- 简单描述：按下遥控器语音键后，RC003 音频直接从 Mac 扬声器播放，表现为爆音或电流声；同时千问收不到 `MiRemoteV 2ch`，可能自动回退麦克风。

## 证据与根因

- 运行日志在电流声会话中记录部分 PCM 峰值达到 Int16 极限，但真正的可听路径是设置在 `06:09:20` 从 `MiRemoteV 2ch` 切换为 `MacBook Air Speakers`。
- 持久化配置随后为 `selectedAudioDeviceUID=BuiltInSpeakerDevice`；重启后 `AUDIO READY` 也明确绑定 Mac 扬声器。
- 千问日志同期记录 `MiRemoteV 2ch` 无声后自动切换到 Mac 内置麦克风，因此电流声和麦克风回退来自同一错误路由。

## 修复

- 复用 `DoubaoAudioDevicePolicy`：千问模式启用且 MiRemoteV 存在时，启动配置与设置页变更都强制解析为 `MiRemoteV2ch_UID`。
- 普通非千问模式仍保留原有输出设备选择能力。

## 验证

- 新增回归证明千问模式把实体扬声器请求锁回 MiRemoteV，普通模式不改写请求。
- 相关 27 项测试通过。
- 原路径复验：启动前故意写入 `BuiltInSpeakerDevice`，修复版启动后持久化值自动恢复为 `MiRemoteV2ch_UID`，日志出现 `QIANWEN AUDIO route_locked`，实际 `AUDIO READY` 为 `MiRemoteV 2ch`。
