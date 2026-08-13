# 通用 CoreAudio 麦克风桥接测试手册

## 适用版本或分支

当前开发工作树；DJI Mic Mini TX 纯蓝牙连接，不使用 Receiver。本轮只做源码集成，不生成测试包。

## 测试前准备

- 安装并确认 `MiRemoteV 2ch` 可用；DJI Mic Mini 已连接；
- 设置 `SAYALL_AUDIO_INPUT_KIT_PATH=/absolute/path/to/sayall-audio-input-kit` 后构建；未设置时功能必须失败关闭；
- 系统输出先选择 MacBook 扬声器，AirPods 单独测试；
- 闪电说 / ASR 输入选择 `MiRemoteV 2ch`；准备 Spotify 或 Apple Music；
- 记录测试前默认输入、默认输出和系统输出。

## 测试用例

1. 旧配置启动：持续桥接默认关闭，不自动弹权限，不启动采集。
2. 首次权限允许：点击“允许使用麦克风”，系统授权后可开启采集；无权限时不得启动 AUHAL。
3. 首次权限拒绝：拒绝系统授权后保持停止并显示权限状态；不得循环弹窗或伪装成设备故障。
4. 权限撤销：已运行后从系统设置撤销权限，桥接必须安全停止；重新授权前不得继续输出。
5. DJI 链路：选择 DJI、MiRemoteV 并开启，说话应进入闪电说转写；默认三设备不得被 App 改写。
6. MacBook 扬声器：音乐持续播放、音质不变，DJI 只作为输入。
7. AirPods：验证 A2DP 播放、掉音、卡顿和 profile 音质；该项不能用自动化替代。
8. RC003 抢占：DJI 运行时触发普通 `STREAM_START → AUDIO → STREAM_STOP`；只能输出 RC003，尾音处理后恢复 DJI。
9. Nearby iOS 抢占：DJI 运行时启动、发送、停止 Nearby 语音；排空后恢复 DJI。
10. Web 手机抢占：DJI 运行时启动、发送、停止 Web 语音；排空后恢复 DJI。
11. 断线重连：关闭并重连 DJI，旧 generation 音频不得进入新会话。
12. 输出重建：MiRemoteV 或系统音频拓扑变化时先停输入，输出就绪后恢复。
13. App 前台：前台开启、持续和关闭桥接均正常，页面状态与日志一致。
14. App 后台：切换到其他 App 后持续采集，再返回关闭；不得暂停、抢焦点或修改路由。
15. 睡眠唤醒：可恢复或显示明确错误，不得崩溃、僵死或修改默认路由。
16. 持续 30 分钟：记录延迟、丢弃缓冲、重建、静音、CPU 和内存趋势。
17. 持续 2 小时：重复记录长期漂移和资源趋势，不得用 30 分钟结果替代。
18. 设置页：当前产品窗口最小尺寸为 `1020 × 772`；逐一点击全部侧边栏入口，主要控件和滚动不得裁切或改变窗口几何。`800 × 650` 不适用于当前版本固定最小窗口，需记录为产品规范差异而非强行缩放。

## 失败判定

- 两路音源混音、旧尾音污染、系统默认路由被 App 修改；
- 输出到系统扬声器而非虚拟麦克风；
- 队列或内存持续增长、延迟不断扩大、不可恢复静音；
- RC003、Nearby、Web、测试音或稳定设置页面回归。

## 日志收集

- App 日志筛选 `AUDIO INPUT`、`AUDIO RECOVERY`、`AUDIO WRITE`、`ATVV STREAM`；
- 必要时运行 `log stream --info --predicate 'process == "RemoteMic" OR process == "coreaudiod" OR process == "bluetoothd"'`；
- 记录默认三设备 UID、DJI/MiRemoteV 采样率和实际 CurrentDevice；日志不得包含真实音频。

## 验证边界

- 自动化：配置、仲裁、格式转换、模拟端点 PCM/重连/旧 generation fixture，以及 RC003 基线；模拟端点测试不直接驱动生产 AUHAL callback；
- 许可证：当前组合仅允许内部开发与测试；完成 GPL 分发边界处理前不得打包或对外发布；
- 代理：构建、权限/签名、短时 DJI → MiRemoteV 和内建扬声器并发；
- 用户/真实环境：闪电说、AirPods、30 分钟、2 小时、睡眠唤醒和现场无线稳定性。

## 当前验证记录（2026-08-13）

- 已完成：测试包 UI 枚举/选择 DJI、AUHAL 16 kHz 单声道启动、MiRemoteV 2ch 双声道非零电平回读、关闭后停止；系统默认三路由在操作前后均保持 DJI（这是测试前已有系统状态，App 未改写）。
- 未完成：闪电说最终转写、音乐共存、AirPods、RC003/Nearby/Web 真机抢占、DJI 断线重连、App 后台、睡眠唤醒、30 分钟和 2 小时。
