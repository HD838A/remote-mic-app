# 本地移植：虚拟音频假正常状态

- 来源：上游 `b989a10`；仅移植宿主健康判断与边界恢复。
- 先执行离线 AVAudioEngine 实验：`start → play → player.stop`，输出 `engine_running=true player_playing=false legacy_ready=true`。不涉及实际音频设备。
- 上游现场现象为重新选择 MiRemoteV 后恢复；本机没有对应故障现场日志，实验只确认宿主旧判断遗漏播放器状态。
- 修复：播放就绪要求 engine 与 player 同时运行，完整检查增加实际设备绑定；每批 PCM 不查询设备绑定。新会话与配置通知读取实时健康状态，健康时不重建。
- 本地续接入口保留在新会话初始化之前，不重复 Fn、统计、映射或重建播放器。
- 新增离线 AVFoundation 回归至现有 TestToneTests；真实 MiRemoteV、微信首句和异常恢复仍按 `Testing/LocalAudioOptimizations.md` 验收。
- `swift test --disable-automatic-resolution`：193 项通过，包括 stopped-player 原始复现；`git diff --check` 通过。
