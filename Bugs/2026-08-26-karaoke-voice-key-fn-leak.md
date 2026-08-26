# 卡拉 OK 返听同时触发系统 Fn 语音识别

- 时间：2026-08-26
- 状态：候选修复完成，等待 RC001 / RC003 真机与系统输入法验收
- 影响范围：本地卡拉 OK、遥控器语音键、Fn / Command 语音触发、普通语音恢复

## 1. 复现 Bug

触发条件：RC003 已连接，语音键使用默认 F5→Fn 硬件映射；在“连接与语音”开启本地卡拉 OK，然后按住语音键说话。

错误行为：遥控器 PCM 能进入本地返听，但同一个实体语音键仍向 macOS 产生 Fn，系统输入法语音识别也被启动。关闭卡拉 OK 后，本地路由会恢复普通虚拟音频，但开启期间没有隔离系统按键副作用。

正常边界：卡拉 OK 仍必须遵守 RC003 固件“按住语音键才发送 PCM”的限制，但开启期间这个按住动作只负责让遥控器产生音频，不能再触发 Fn / Command；关闭后才恢复用户原有语音键模式。

## 2. 查看日志

现场 `runtime.log` 在 2026-08-26 14:15 UTC 记录：

```text
VOICE FN MAPPING applied=true neutralized=false ... matched=1 applied=1
KARAOKE MODE enabled trigger=settings input=voice_button ...
ATVV AUDIO routed trace=11 model=rc003 route=local_karaoke accepted=true ...
KARAOKE MODE disabled reason=settings ...
ATVV AUDIO routed trace=12 model=rc003 route=virtual_audio accepted=true ...
```

这证明音频路由开关本身有效：开启期间是 `local_karaoke`，关闭后回到 `virtual_audio`。同时 `neutralized=false` 证明 HID 层仍保留 F5→Fn 映射；“没有在软件层注入 Fn”不等于“实体按键不会由硬件映射产生 Fn”。

## 3. 查看代码与根因

旧卡拉 OK 分支只让语音流绕过 `updateVoiceKeyState` / Fn 点按会话并进入独立播放器，没有在开启模式前改变 `RemoteVoiceFunctionMapper`。正常 HID 设置仍执行 `applyVoiceFunctionMapping(neutralizeVoiceKey: false)`，把 RC003 语音键映射为 Fn。

根因是隔离发生在音频/软件注入层，但副作用来自更早的 HID `UserKeyMapping` 层。两个路径并不互斥，所以本地返听正确也仍会启动输入法。

## 4. 修复

1. 开启卡拉 OK 前，先复用现有 HID 映射器把遥控器语音键目标改为 `0`，并确认 `isVoiceKeyNeutralized == true`；失败时拒绝开启返听。
2. 模式开启期间的权限变化、重连及 HID 设置重应用继续维持中和；真实语音流开始时再次做失败关闭门禁，避免状态漂移后泄漏 Fn。
3. 空闲关闭时立即恢复用户的 Fn、Fn 点按或左右 Command 设置；活动流关闭时等停止、断连或超时收尾完成后再恢复，避免松开事件在尾部泄漏。
4. 卡拉 OK 输出新增独立持久化设备选择，只接受物理输出；它不读取或修改普通 `selectedAudioDeviceUID`，设备暂时不可用时只临时回退到系统物理输出。

## 5. 验证

- `swift test --filter KaraokeModeTests`：10 项通过，覆盖独立输出优先、虚拟设备排除、选择持久化和配置导入导出、普通语音输出保持不变，以及生产代码中语音键中和、流开始失败关闭和模式关闭恢复的接线。
- `swift test`：415 项、37 个 suite 全部通过；`scripts/test.sh`：43 项自检与 7 类 RC003 历史日志夹具通过。
- `swift build -c release` 与项目原生 App Debug 构建通过；`git diff --check` 通过。现有弃用提示来自未改动的 SwiftUI `onChange` 调用，不影响本次编译结果。
- 使用项目原生 App 结构在 `800 × 650` 渲染并检查中文浅色、中文深色和英文浅色“连接与语音”：系统输出选项完整显示，代表性物理设备使用页面内网格，长设备名只在按钮中截断；没有新增下拉框、Popover、Sheet 或小于 12pt 的中文文字。
- 既有 `RemoteVoiceFunctionMapperTests` 覆盖中和成功、部分失败回滚和恢复，不重复模拟私有系统输入法行为。
- 仍需 RC001 / RC003 真机确认：开启时日志先出现 `KARAOKE VOICE KEY neutralized=true`，按住语音键可返听但系统输入法不启动；关闭后正常 Fn / Fn 点按 / Command 行为恢复；活动流中关闭、断连和超时路径不泄漏尾部按键。
- 当前界面检查 App 为内部 ad-hoc 构建，不作为安装包交付。自动化、编译和日志分析不能代替真实 HID、TCC、输入法及耳机/扬声器声学验收。
