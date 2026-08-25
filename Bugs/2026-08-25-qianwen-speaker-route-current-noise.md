# 千问语音输出误选 Mac 扬声器产生电流声

- 时间：2026-08-25
- 状态：补充失败关闭修复，自动化通过，等待 MiRemoteV 暂时不可用的真机复验
- 影响范围：开启千问兼容模式后，语音输出设备被改成实体扬声器
- 简单描述：按下遥控器语音键后，RC003 音频直接从 Mac 扬声器播放，表现为爆音或电流声；同时千问收不到 `MiRemoteV 2ch`，可能自动回退麦克风。

## 证据与根因

- 运行日志在电流声会话中记录部分 PCM 峰值达到 Int16 极限，但真正的可听路径是设置在 `06:09:20` 从 `MiRemoteV 2ch` 切换为 `MacBook Air Speakers`。
- 持久化配置随后为 `selectedAudioDeviceUID=BuiltInSpeakerDevice`；重启后 `AUDIO READY` 也明确绑定 Mac 扬声器。
- 千问日志同期记录 `MiRemoteV 2ch` 无声后自动切换到 Mac 内置麦克风，因此电流声和麦克风回退来自同一错误路由。

## 修复

- 复用 `DoubaoAudioDevicePolicy`：千问模式启用且 MiRemoteV 存在时，强制解析为当前枚举到的 MiRemoteV UID。
- 千问模式启用但 MiRemoteV 暂时不可用时，运行时有效 UID 解析为空；`VirtualAudioOutput.configure("")` 会先停止旧输出并返回“未选择设备”，不会回退系统扬声器。
- 启动、设置页、配置导入、系统音频恢复和语音开始前的重绑统一经过同一策略；不再只保护启动与 Picker 两个入口。
- 持久化值保留 MiRemoteV 的预期 UID，使设备重新出现时仍能由硬件变化恢复，不把实体扬声器保存为千问输出。
- 普通非千问模式仍保留原有输出设备选择能力。

## 验证

- 新增回归证明千问模式把实体扬声器请求锁回 MiRemoteV；MiRemoteV 缺失时有效 UID 为空且持久化预期 UID；普通模式不改写请求；所有运行时重绑均重新执行策略。
- 同步最新官方主分支后的基线 413 项测试通过；本轮 20 项千问、音频、TV 和会话定向测试通过。
- 原路径复验：启动前故意写入 `BuiltInSpeakerDevice`，修复版启动后持久化值自动恢复为 `MiRemoteV2ch_UID`，日志出现 `QIANWEN AUDIO route_locked`，实际 `AUDIO READY` 为 `MiRemoteV 2ch`。

## 验证边界

- 自动化已经证明空 UID 会停止输出且不会选择系统默认设备，也证明配置导入和恢复重绑不能绕过策略。
- 仍需在安装包中让 MiRemoteV 暂时不可用，确认按语音键无扬声器声音；恢复设备后确认自动重新绑定，并再次执行 RC003、千问和 TV 真机基线。
