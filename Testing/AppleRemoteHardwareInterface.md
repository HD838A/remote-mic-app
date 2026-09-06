# Apple Remote 通用硬件接口与 A2854 实机测试手册

## 适用范围

- 日期：2026-09-05。
- 目标硬件：第三代 Siri Remote A2854（USB-C）。其他代际不在本手册兼容范围内。
- 当前状态：已实现 A2854 候选适配器、通用生命周期接线、设备档案、Siri 键即时会话、候选触摸输出，以及由安装包管理的系统 PacketLogger/HCI → Opus → PCM → `MiRemoteV 2ch` 音频桥接；本次 Developer ID Release App 已完成签名、公证、staple 和 Gatekeeper 验证。真实硬件音频与完整新机安装器仍需实机验收。
- 目标：验证候选实现的按键边沿、触摸、断连恢复和现有稳定设备回归。通过本手册前不得对外声明 Apple Remote 已正式受支持。
- 跨型号与跨平台的基础功能、事件生命周期和发布门禁见 [`Testing/HardwareCompatibilityContract.md`](HardwareCompatibilityContract.md)；本手册只增加 A2854 专属能力与实机步骤，不重新定义通用行为。
- 通用语音完整性门槛见 [`Testing/HardwareVoiceAudioContract.md`](HardwareVoiceAudioContract.md)；本手册不得降低“首字尽快、尾字完整、正常路径不 flush”的要求。

## 本地测试包

| 项目 | 值 |
| --- | --- |
| App | `/Users/andy/.codex/worktrees/2f42/open-voice-bridge/dist/SayAll.app` |
| 构建时间 | 2026-09-05 19:39（CST） |
| 配置 | Release，Apple Silicon `arm64`，最低 macOS 14.0 |
| 版本 | 1.9.19（172） |
| Bundle ID | `com.hd838a.RemoteMic` |
| 源码基线 | `9e019112fc88` 加当前未提交的 Apple Remote 候选改动 |
| 主程序 SHA-256 | `9647acacaaf29c39d3aeda0bc605b93b6a67a5eac05660173bd007027f84633e` |
| Apple Remote HCI helper SHA-256 | `3aa9e9080242aa605117c56f0be7d0bb554a8af67c0972a9b5af8a47be7a423d` |
| Apple Remote audio helper SHA-256 | `870e36ddea1e196511dd6a96e04efe877c0de57ccea7e1e24902b809e2501eef` |
| 包内 libopus SHA-256 | `964086a9a2b0446b68b342c4cc66accd80b22c19602bede8aae9f75782bedd00`（`arm64`，最低 macOS 14.0） |
| 包体积 | 约 `15 MB` |
| 签名 | Developer ID Application `L3QHLDRPAY`；`codesign --verify --deep --strict` 已通过 |
| 安装器签名 | 本次交付只重建了 App/ZIP；`dist/*.pkg` 未随本次交付重建 |
| 公证/Gatekeeper | Apple 公证已接受；staple、`stapler validate`、`spctl --assess --type execute` 和 `codesign --deep --strict` 均通过 |
| 可分发 ZIP | `/Users/andy/.codex/worktrees/2f42/open-voice-bridge/dist/SayAll-apple-remote-alignment-stapled-20260905-1944.zip`，SHA-256 `1d3d3975356513593e1b167d42f36ba5defd0ba5ac17891eab08f0b4162d7125` |

此包只用于本机候选功能测试，不可作为正式发布包分发。Developer ID、Hardened Runtime、公证、staple 和解压后 Gatekeeper 校验已经通过，但这些产物检查不能证明私有 `MultitouchSupport` 的真实回调在目标系统上可用，仍需 A2854 实机验证。

## 本次 `.app` 测试与首次授权

用户不需要安装 PacketLogger、Bluetooth Logging Profile、Homebrew、额外硬件或 Apple Developer 账号。正式安装包应负责安装无线麦SayAll.app、音频 helper、内置 `libopus` 和 root HCI helper；PacketLogger 只作为系统私有 XPC 服务名存在，最终用户不需要下载或打开它。本次交付的 `.app` 只用于已有组件的本机测试。

1. 解压本次 ZIP，或直接双击 `dist/SayAll.app`；也可以先复制到 `/Applications` 再打开。
2. 本次 `.app` 不负责把特权 HCI helper 和 `MiRemoteV 2ch` 写入全新系统。当前测试机已存在并运行这两个组件；全新机器必须使用包含它们的正式安装包后再做 Siri Remote 语音验收。
3. 启动无线麦SayAll.app；如果测试机尚未完成 HCI helper 授权，按系统提示输入管理员密码。

4. 在 SayAll 的“权限”页按提示授予蓝牙、输入监控和辅助功能权限。完成后完全退出并重新打开 App。

5. 连接 A2854，进入 Apple Remote 音频测试；App 会显示 `preparing_hci → authorizing → ready`，不要求用户操作 PacketLogger。
<!-- HCI 配置、授权项和 bluetoothd 恢复均由安装包 helper 管理，用户不需要手工执行命令。 -->

卸载使用 `dist/Uninstall SayAll.pkg`。卸载前后应确认 HCI plist 与 `com.apple.PacketLogger.HCI` right 恢复到安装前状态；如果安装前不存在配置，恢复动作应把 helper 创建的空 plist 移入 macOS Trash，而不是永久删除。

失败判定：缺少 PacketLogger 时日志应为 `unavailable:packetlogger_missing`；跟踪项未完整开启时应为 `unavailable:hci_voice_tracing_disabled`。两种情况都不得自动改用 Mac 麦克风。

上面的 `packetlogger_missing` 仅保留作旧构建日志兼容说明；当前安装包不要求用户安装 PacketLogger。新构建统一使用 `hci_voice_tracing_disabled` 或授权失败码，并且不会回退到 Mac 内置麦克风。

2026-09-05 已在本机确认 `/Applications/PacketLogger.app` 不存在，并运行无 PacketLogger 探针：系统 PacketLogger XPC 可建立连接并收到 HCI 记录，10 秒内 `frames=0 samples=0`，结束后 HCI 配置由 helper 恢复；该结果只证明不依赖 PacketLogger.app 安装包，不证明真实 A2854 音频已通过。随后最新构建已在真实已配对 A2854 上进入 `packet_stream phase=ready result=authorized`，但尚未产生真实 PCM 或豆包转写。

## 最快测试流程（约 15 分钟）

### 1. 配对遥控器

1. 确认遥控器型号为 A2854（USB-C 版）。
2. 打开“系统设置 → 蓝牙”。让遥控器靠近 Mac，同时按住“返回”和“音量加”约 5 秒，等待它出现在蓝牙设备列表并完成连接。
3. 如果遥控器已经配对但没有响应，先按任意键唤醒；仍无响应时断开后重新连接。

预期结果：系统蓝牙列表显示遥控器已连接。失败判定：系统本身无法发现或连接设备，此时先不要继续判断 App 功能。

### 2. 启动本地 App 并授权

1. 直接双击 `dist/SayAll.app`，也可以先复制到 `/Applications` 再打开。App 是菜单栏应用，启动后主要入口在菜单栏，不一定显示 Dock 图标。
2. 如果系统阻止打开，前往“系统设置 → 隐私与安全性”确认打开；本包已公证，不应出现“未公证”拒绝。
3. 在无线麦设置的“权限”页面依次开启蓝牙、输入监控和辅助功能。macOS 要求时，完全退出 App 后重新打开。
4. 打开“自定义按键”，开启“启用自定义按键功能”。

预期结果：连接状态显示“Apple Siri Remote 已连接”，遥控器出现在设备选择区，名称为“Apple Siri Remote（A2854）”。失败判定：授权并重启后仍只显示正在查找，或者按键会操作系统但 App 没有任何响应。

### 3. 快速验证实体键

依次各按 3 次：上、下、左、右、中心、返回、TV、音量加、音量减、播放/暂停、静音、电源。

预期结果：

- 全部 12 个可配置实体键执行当前 A2854 档案为它们配置的动作，每次物理操作只执行一次。
- 播放/暂停、静音、电源和音量键配置为非原生动作时，只执行配置动作，不得同时改变系统媒体、音量或电源状态。
- 在按键页面观察时，Siri、中心、播放/暂停、静音、电源及其他实体键按下期间，对应卡片显示橙黄色活动描边，松开后恢复。

失败判定：一次按键执行两次、松开后仍持续执行、方向键同时带出鼠标动作、自定义动作与系统原生动作同时发生，或任一控制项按下后没有活动描边。

### RC001/RC003 功能对齐矩阵

| 能力 | Siri Remote 当前状态 | 验收要求 |
| --- | --- | --- |
| 设备独立配置 | 已接入独立 profile、映射和统计 | 多遥控器配置不串用，重连后保持 |
| 单击、双击、长按 | 已复用通用手势识别器 | 时序与 RC001/RC003 一致；配置次级手势后单击不连发 |
| 按住连发 | 候选实现已对齐：350 ms 后开始；返回 50 ms，方向/音量 100 ms | 返回键连续删除，方向连续导航，音量连续变化；松键立即停止 |
| 快速连按选项 | 尚未按 RC001/RC003 的 600 ms 稳定释放门禁逐项真机确认 | 开关关闭/开启的行为应与设备档案一致，不能误吞真实快速点击 |
| 键位方案与编辑捕获 | 已接入公开映射与私有键位方案入口 | 编辑页只选键不执行；离开编辑步骤后立即恢复动作 |
| App 切换器完整生命周期 | 尚未对齐 RC001/RC003 的左右选择、确定确认、返回取消 | 当前只能视为基础 `Command-Tab` 候选，不得宣称完整一致 |
| 断连、权限和配置取消 | 已有设备级取消，连发计时器随之清理 | 不留下按住、重复、Fn、触摸或旧 generation 状态 |
| 语音键生命周期 | 已接入即时按下/释放、遥控器麦克风和无损尾包排空 | 首字快、尾字全、快速再次按下不丢开头 |
| 语音期间触摸屏蔽 | 候选实现已增加 | 从 Siri 按下到尾音排空完成无移动、滚动、点击；新接触随后恢复 |
| 电池/充电状态 | 尚未接入等价状态 | 未实现前显示未知，不伪报健康或电量 |
| 物理键能力差异 | 播放/暂停、静音和电源均进入独立 A2854 档案映射；A2854 没有 RC 的 Home/Menu 同构按键 | 自定义映射启用时原生系统副作用被抑制；UI 不展示不存在的 Home/Menu |

快速连按、App 切换器完整生命周期和电池状态仍是后续对齐项，不在本次修改中顺带实现。

### 4. 快速验证 Siri 语音键与遥控器麦克风

1. 确认首次管理员授权已经完成；不需要安装或打开 PacketLogger。
2. 在 SayAll 音频设置中确认输出设备为 `MiRemoteV 2ch`，并在豆包中把输入设备选择为同一个 `MiRemoteV 2ch`。
3. 连续做 10 次很快的“按下后立即松开”。
4. 再做 3 次正常按住 2 至 5 秒后松开，说一小段可识别的话。
5. 最后按住 Siri 键时关闭遥控器连接或退出 App，再重新连接并做一次正常按住。
6. 每次语音按住期间分别移动手指、轻触和转动触摸盘；松键后继续保持当前接触，再抬手并开始一次新触摸。

预期结果：按下立即开始会话，松开后等待尾音自然排空再完成；helper 报告 `capturing`，日志出现遥控器麦克风首批 PCM，并且 `MiRemoteV 2ch` 电平随遥控器说话变化；豆包最终收到遥控器声音。极速短按不丢失，断连或退出后 Fn/语音状态不会卡住，重连后的第一次操作即可成功。语音活动及尾音排空阶段不产生触摸移动、滚动或点击；语音期间已经开始的接触不会在恢复瞬间补发点击，抬手后的下一次新触摸正常工作。

失败判定：需要等到“长按阈值”才开始、尾音排空后仍在录音、日志只有 `audio_source=mac_microphone`、没有 `capturing`/PCM、`MiRemoteV 2ch` 电平始终为零、首次会话失败但第二次才成功、Siri 键触发聚焦输入框等附加动作，或语音期间触摸仍移动指针/滚动/点击。

系统 HCI 语音跟踪不可用时的明确结果：App 必须记录 `APPLE REMOTE AUDIO status=unavailable:hci_voice_tracing_disabled` 或对应授权失败原因，语音会话可以按生命周期开始/结束，但不得回退到 Mac 麦克风，也不得把“收到 Siri 键”当作音频成功。

### 5. 快速验证触摸

1. 在 Safari 长页面和 Finder 列表中分别测试触摸移动、轻触点击和外圈顺/逆时针转动。
2. 测试慢速一圈和快速一圈，观察滚动方向、步幅和是否突跳。
3. 按住方向环或中心实体键时移动手指，确认不会同时移动鼠标或点击。

预期结果：指针移动稳定、轻触只点击一次、外圈可以连续滚动，触摸结束后不漂移。失败判定：完全没有触摸回调、App 退出、点击重复、滚动方向相反、快速滚动失控，或实体按压附带鼠标动作。

### 6. 重连与反馈

1. 断开并重连遥控器两次；每次重连后立即测试方向键和 Siri 键。
2. 记录发生问题的本地时间，然后查看 `~/Library/Logs/RemoteMic/runtime.log` 中同一时间附近、以 `APPLE REMOTE` 开头的完整事件链。
3. 反馈时请附 macOS 版本、A2854 型号确认、复现时间、操作步骤、实际/预期结果和相关日志。不要附输入内容、窗口标题、蓝牙地址、序列号或其他个人信息。

预期结果：无需重启 App，重连后的第一枚按键和第一次语音会话即可工作。多只 Apple Remote 同时连接时，候选实现会关闭触摸，避免把触摸错误归属到另一只设备。

## 真实音频链路与接口边界

真实音频路径为：遥控器内置麦克风 → 系统 PacketLogger XPC/HCI 捕获 → A2854 语音通知重组 → Opus 解码 → PCM → `MiRemoteV 2ch` → 豆包。PacketLogger 服务由系统提供并由安装包 helper 管理，用户不需要单独安装；没有系统 HCI 语音跟踪能力时只能验证失败可观测性，不能完成真机音频验收。

### Siri 键释放后的电平尾部回归

每次语音会话都要记录按下、松开和释放后的完整链路。重点查看以下字段：

```text
APPLE REMOTE AUDIO packet_stream phase=capture_stopped ... generation=<n>
APPLE REMOTE AUDIO capture_stop phase=completed result=tail_settled completion=normal ...
APPLE REMOTE AUDIO playback_stop phase=completed result=drained ...
    pending_before_buffers=<n> pending_before_samples=<n>
    pending_after_buffers=0 pending_after_samples=0
    played_buffers=<n> played_samples=<n>
    interrupted_buffers=<n> interrupted_samples=<n>
```

预期：松开后先进入 closing，同一 generation 的在途尾包继续计入 `closing_samples`；随后输出自然排空，`pending_after_buffers=0`、`pending_after_samples=0` 且 `interrupted_samples=0`。失败判定：正常释放出现 `completion=forced`、`stale_generation`、`interrupted_samples > 0`，或 `playback_stop` 缺失、释放后 pending 仍大于 0。

### 4.1 快速再次按下（连续无损边界）

1. 说出第一句话，松开 Siri/语音键；在日志出现 `playback_stop phase=waiting_for_capture_tail` 后，
   立即再次按住并说出第二句话。
2. 重复 5 次，分别让第二次按下发生在：helper stop 尚未确认、已确认但尾包静默窗口内、以及
   `MiRemoteV 2ch` 仍在排空时。

预期结果：日志出现 `APPLE REMOTE VOICE phase=resumed result=continued_session reason=rapid_repress`；
第二句话的首字完整；整个连续会话只在第二次松开后结束。失败判定：出现
`deferred reason=previous_session_draining`、第二段首字缺失、旧 generation 的第二段 PCM 被记录为
`stale_generation`，或 Fn 在两段之间释放。

如果音频链路在 `preparing_hci` 阶段失败，先收集以下成对日志：

```text
APPLE REMOTE HCI XPC phase=connecting client_identifier_matches=<bool> client_team_matches=<bool> client_signature_adhoc=<bool>
APPLE REMOTE HCI XPC phase=failed result=remote_proxy_error error_domain=<domain> error_code=<code>
APPLE_REMOTE_HCI_SERVICE connection_rejected reason=<reason>
```

其中 `team_matches=false` 或 `client_signature_adhoc=true` 表示本地构建没有使用目标 Developer ID，
不应把它误判为 PacketLogger 或蓝牙故障。

连续执行 10 次短按（每次说一个短词）和 5 次持续 5 秒的语音，分别检查：

1. 每次都出现唯一的 `capture_stopped`、`playback_stop` 和语音结束事件。
2. 不出现下一次会话继承上一代 PCM 的情况。
3. 松键后的有效尾包计入原会话的 `closing_samples`；正常结束不得主动丢弃这些样本。

通用接口只负责把设备报告标准化为以下事实：

1. 设备实例、稳定控制项 ID、基于系统 uptime 的时间戳和单调递增的进程内序号；
2. 即时 `began`、`ended` 和带原因的 `cancelled`；
3. 重复按下、无匹配释放和配置切换后迟到释放的稳定忽略原因；
4. 设备级断连取消与多设备隔离；
5. 触摸点和设备专用触摸调优值。

普通按键的双击、长按和动作执行仍由现有宿主组件负责。Siri 键不进入普通手势识别器：按下立即合成当前语音键 down 并开始遥控器麦克风会话，释放或取消立即释放对应 owner；没有 Apple Remote 音频时不得回退到 Mac 麦克风。

当前实体键边界：方向、中心、返回、TV、音量、播放/暂停、静音和电源均复用现有 `RemoteButton` 档案映射；Siri 键保持固定即时语音生命周期。自定义映射启用时，宿主必须抑制同一物理边沿对应的原生键盘或系统媒体事件，不能让配置动作与系统原生动作同时发生。

## A2854 触摸实验初值

以下参数来自 `luobosibing2/codex-siri-remote` 的部分 A2854 实机调优，只作为第一轮实验起点：

| 参数 | 初值 |
| --- | ---: |
| 外圈最小归一化半径 | `0.35` |
| 圆周滚动启动阈值 | `0.2` |
| 每弧度滚动像素 | `30` |
| 滚动平滑系数 | `0.3` |
| 最小加速度倍率 | `1.0` |
| 最大加速度倍率 | `1.3` |
| 初始滚动反向 | `true` |

参数存在于 `RemoteHardwareTouchTuning.appleSiriRemoteA2854Experimental`。正式默认值必须以 SayAll 的签名构建、目标 macOS 范围和真实 A2854 测试结果为准。

## 测试前准备

1. 使用包含 Apple Remote 内置适配器的候选构建；记录 App 版本、Build、源码 revision 和签名类型。
2. 准备一只确认型号为 A2854 的 Siri Remote；如果测试多设备隔离，再准备第二只遥控器或一只稳定 RC001/RC003。
3. 覆盖至少一台 macOS 14 Apple Silicon Mac 和一台当前支持的 macOS 26 Apple Silicon Mac。
4. 授予蓝牙、输入监控和辅助功能权限。触摸实现若使用私有 `MultitouchSupport`，必须分别测试本地开发签名和 Developer ID + Hardened Runtime + 公证产物。
5. 准备 Safari 长页面、Finder 列表、一个 Electron 输入应用和无线麦SayAll.app 设置页。
6. 保存测试起始时间。运行日志不得记录遥控器名称、蓝牙地址、序列号、设备 UUID、窗口标题或输入内容。

## 实机覆盖矩阵

| 维度 | 必测组合 | 通过标准 |
| --- | --- | --- |
| 系统 | macOS 14、macOS 26 | 配对、按键和触摸结果一致；差异有明确降级 |
| 构建 | 本地签名、Developer ID + Hardened Runtime、公证安装包 | 触摸回调不导致进程退出，权限可恢复 |
| 设备状态 | 首次配对、已配对启动、睡眠唤醒、断连重连 | 不重启 App 即可恢复，未留下按住状态 |
| 前台应用 | Safari、Finder、Electron、SayAll | 点击和滚动落在预期前台窗口 |
| 显示环境 | 单显示器、双显示器、全屏、Split View | 指针、点击和滚动不落到错误窗口 |
| 设备组合 | 仅 A2854、A2854 + RC001/RC003、两只同型号设备（条件允许时） | 同名控制项按设备实例隔离 |
| 权限 | 完整授权、撤销输入监控、撤销辅助功能、恢复授权 | 明确失败和恢复，不崩溃、不误执行 |

### 安装、授权与恢复矩阵

| 场景 | 操作 | 通过标准 |
|---|---|---|
| 首次安装 | 安装 `Install SayAll.pkg`，启动 App，首次进入 Apple Remote 音频 | 仅出现一次标准管理员认证；不要求 PacketLogger 或 Apple 账号；HCI helper 与 App 均能启动 |
| 已授权重启 | 退出并再次启动 App，重新开始一次音频会话 | 不重复弹管理员认证；PacketLogger 状态按 `preparing_hci → connecting → ready` 恢复 |
| App 崩溃/强杀 | 在授权后强制结束 App，再重新启动 | helper 清理租约；全局 right 恢复；重启后第一次会话即可成功 |
| helper 重启 | 重启 `AppleRemoteHCIService`，保持 App 不退出 | App 报告不可用并可重新准备；不遗留旧 HCI 配置或授权项 |
| 安装升级 | 用新 PKG 覆盖旧版本 | 旧配置保留；授权项不会扩大到其他 Bundle ID；新版本可重新建立租约 |
| 卸载 | 运行 `Uninstall SayAll.pkg` | App、helper、driver 移除；HCI plist/right 恢复安装前状态；创建的空 plist 只移入 Trash |

## 用例一：识别与配对

1. 在系统蓝牙中配对 A2854 并启动候选 App。
2. 检查适配器只接受批准的 Apple Vendor/Product/usage 组合。
3. 连接其他 Apple 蓝牙设备，确认不会被当作遥控器 seize 或路由。

预期结果：A2854 显示为候选设备；其他 Apple 设备不进入遥控器事件链路。日志只记录稳定模型分类和进程内设备槽位。

失败判定：错误识别其他设备、需要重启才能发现、记录真实设备标识，或连接导致其他输入设备失效。

## 用例二：全部实体键边沿与重复报告

1. 依次短按方向环、中心、返回、TV、Siri、播放/暂停、音量、静音和电源键；每键重复 20 次。
2. 保持返回键为默认“向后删除”且不配置双击/长按，在文本框中按住 2 秒。
3. 依次按住方向键和音量键 2 秒，再松开并观察是否立即停止。
4. 给返回键增加任意双击或长按动作，再按住 2 秒，确认单击动作不连发且只按配置触发次级手势。

预期结果：每次物理操作只产生一组 `began → ended`；同一物理键跨多个 HID 接口的重复报告被合并。返回键约 350 ms 后开始连续删除，方向键持续导航，音量持续变化；返回键重复间隔为 50 ms，方向和音量为 100 ms，松键后立即停止。存在双击/长按配置时不启动单击连发。全部 12 个可配置实体键执行当前设备档案映射；当播放/暂停、静音、电源或音量配置为非原生动作时，系统原生动作不得同时发生。

失败判定：短按一次执行多次、按住只执行一次、连发开始前明显超过 350 ms、松键后仍继续、配置了双击/长按仍发生单击连发、只有 down 没有 up、自动重复被误判为释放，或系统键被意外接管。

## 用例三：语音键低延迟生命周期

1. 保持现有语音键模式；Siri 键由适配器固定接入即时语音会话，不提供聚焦输入框、双击或长按绑定。
2. 连续执行 20 次极速按下/释放，再执行 10 次正常按住说话。
3. 在语音键按住时分别触发 App 退出、适配器停止、权限撤销和遥控器断连。

预期结果：按下立即产生 `began`，释放立即产生 `ended`；没有双击等待或长按阈值。异常路径产生一次 `cancelled` 并释放所有 Fn、音频和会话 owner 状态。

失败判定：首个响应存在手势等待、短按丢失、释放延迟、断连后 Fn 卡住、第二次或第三次会话才成功。

## 用例四：配置切换与迟到释放

1. 按住普通按键，在不松开的情况下修改或切换该设备映射。
2. 等待配置生效后松开物理按键。
3. 再重新完整按下一次该键。

预期结果：配置切换先发出一次 `cancelled reason=configuration_changed`；随后迟到的旧 release 被抑制，不按新配置产生点击；下一次完整按压正常工作。

失败判定：迟到 release 触发新动作、新按下被永久阻塞，或旧动作保持按住。

## 用例五：断连、睡眠与多设备隔离

1. 同时按住两个不同按键，然后断开 A2854。
2. 重连后执行普通按键和语音会话。
3. 完成五轮睡眠、唤醒和重连。
4. A2854 与 RC001/RC003 同时连接时，让两只设备分别按同名方向键和语音键。

预期结果：断连为该设备的全部活动控制项各产生一次取消；另一设备不受影响。重连后第一枚按键和第一次语音会话即可成功。

失败判定：取消数量不足或重复、另一设备被取消、重连后需要重启、旧 sequence 混入新连接或语音 owner 串线。

## 用例六：触摸、点击、拖拽与滚动

1. 验证单指移动、轻触点击，以及按下方向环或中心键时当前触摸 contact 被抑制，不同时产生鼠标动作。
2. 使用初始参数在 Safari、Finder、Electron 和 SayAll 中沿外圈慢速、正常和快速转动。
3. 分别测试顺时针/逆时针、系统自然滚动开/关、单/双显示器、全屏和 Split View。
4. 让遥控器休眠后直接触摸唤醒并重复操作。

预期结果：指针稳定，无明显静止漂移；点击只触发一次；实体方向环或中心按压不附带移动或点击；滚动方向一致且低速可精确控制、快速不突跳。触摸结束和断连不会留下输入状态。

失败判定：Hardened Runtime 下进程退出、触摸无回调、点击重复、实体按压附带鼠标动作、滚动反向或跨窗口、快速滚动失控。

## 用例七：权限与失败恢复

分别撤销输入监控和辅助功能权限，再恢复授权并重新激活 App。

预期结果：权限缺失时适配器停止相应能力并取消活动控制项，不继续执行动作；恢复后无需清除设备配置即可重新工作。

失败判定：静默失败、权限撤销后仍执行、恢复后必须删除配置，或产生持续权限弹窗。

## 稳定功能回归

- RC001/RC003 的普通按键、按住连发、双击、长按、断连和多设备 profile 不变。
- RC003 无需主动 `MIC_OPEN` 的 `STREAM_START → AUDIO → STREAM_STOP` 仍通过。
- Nearby iPhone、Apple Watch、Web Remote 和 Mac 麦克风入口不受影响。
- 语音键仍遵守即时按下/释放，不增加定位输入框、双击窗口或长按阈值。
- Apple 适配器关闭或缺失时，现有稳定行为与正式版等价，且不会启动无关扫描或请求权限。

## 日志验收

后续适配器接入时，生命周期日志使用稳定字段并聚合高频重复报告，例如：

```text
HARDWARE CONTROL phase=began source=physical_remote adapter=apple_siri_remote control=voice sequence=12
HARDWARE CONTROL phase=ignored reason=duplicate_begin coalesced_events=5
HARDWARE CONTROL phase=cancelled reason=device_disconnected cancelled_controls=2
```

日志必须能区分 received、normalized、routed、cancelled 和 ignored，不能把收到 HID 报告写成功能成功。不得写入真实 `instanceID`、蓝牙地址、序列号、UUID、用户内容或窗口标题。

收集步骤：记录测试开始时间，复现后从“设置”中的诊断入口复制对应时间段日志；若需要直接查看本地日志，只检查 `~/Library/Logs/RemoteMic/runtime.log` 中以 `APPLE REMOTE` 开头的行。提交问题时截取从 `CONNECTION`、`CONTROL` 或 `TOUCH phase=started` 到对应 `completed`、`cancelled` 或 `failed` 的完整链路，不附带其他用户内容。

## 自动化、代理实测与用户实测边界

## Siri Remote 按键设置页面 E2E

适用构建：设置了 `SAYALL_SIRI_REMOTE_PACKAGE_PATH` 的私有功能构建；页面仅对型号为
`Apple Siri Remote（A2854）` 的设备档案显示，RC001/RC003 继续使用原有小米页面。

1. 连接 A2854，进入“按键”页面并选择 A2854 档案。
2. 确认页面图片为 A2854 真机图，左/右连接线分别落在返回、播放/暂停、静音、音量和电源等实体键位置。
3. 确认可配置键只有：电源、上、左、选择、右、下、返回、TV、播放/暂停、音量加、静音、音量减；不存在 Home/Menu，Siri 键显示为固定语音卡。
4. 确认左右两列相邻卡片中心距与 RC003 一致，为 `82.65 pt`；顶部“电源”键卡片位于左列，“右”键卡片位于右列，两列卡片数量差不超过 1；全部卡片无重叠。
5. 分别点击播放/暂停、静音、电源和音量减的单击设置入口，配置四个容易区分且安全的非原生动作；退出页面再进入，确认配置按 A2854 档案持久化。
6. 依次按下 Siri、中心、播放/暂停、静音、电源，再覆盖其余实体键；按住期间对应卡片应显示橙黄色活动描边，松开后恢复。Siri 只显示状态，不出现普通按键编辑入口。
7. 实机各按一次播放/暂停、静音、电源和音量减，确认只执行配置动作；媒体播放状态、静音状态、系统音量和电源状态不得同时变化。
8. 切换到 RC001/RC003 档案，确认页面恢复原有小米图片和 12 键布局；切回 A2854 后配置仍保持独立。
9. 在窗口 `800 × 650` 和 `1020 × 772`、浅色与深色外观分别检查：图片、连接线、卡片、语音卡和底部说明无重叠、裁切或中文缩小到 12pt 以下。

通过标准：A2854 页面与小米页面完全隔离；全部 12 个实体键可编辑并持久化；自定义媒体、音量和电源动作不伴随原生副作用；全部物理键活动态准确；Siri 键不可被普通按键映射覆盖；所有受影响控件可点击。

失败判定：A2854 显示小米图片或 Home/Menu、任一配置无法保存、配置动作与系统原生动作同时发生、物理按下没有活动描边、电源键仍位于右列、右键位于左列、左右卡片数量明显失衡、卡片间距明显大于 RC003、Siri 键出现双击/长按编辑、切换档案污染另一档案，或任一窗口尺寸出现遮挡/裁切。

自动化边界：私有 Package 页面控制项集合、固定 Siri 卡和资源加载由 Package 测试覆盖；宿主路由、可配置键集合与 RC 页面隔离由宿主回归测试覆盖。真实窗口点击、系统外观截图和 A2854 物理按键仍需用户在本机完成。

- 已由自动化覆盖：精确 VID/PID/usage page 筛选、实体键 usage 映射、媒体/静音/电源通用映射、原生事件抑制候选、原始 control ID 活动态、电源键左列、右键列、左右列数量平衡、与 RC003 一致的 `82.65 pt` 卡片间距、任意非零 HID 值保持 pressed、设备实例隔离、即时 down/up、重复 down、无匹配 up、断连取消、配置切换后的迟到 up、确定性取消顺序、单调 sequence、Apple 语音 owner 隔离、设备档案不污染小米蓝牙档案、A2854 中心移动/轻触/外圈阈值/方向/实体按压抑制/取消复位、语音活动与尾音排空期间触摸抑制、抑制接触必须抬手后恢复、按住连发策略，以及 PacketLogger 文本解析、pklg ACL 分片重组、IPC 分片解码和 PCM 编解码。
- 尚未由自动化覆盖：真实 IOHID 多接口报告、Hardened Runtime 下的 `MultitouchSupport` 真实回调、系统蓝牙配对、PacketLogger 真正 HCI 输出、Opus 固件帧兼容性、权限 TCC、CGEvent 最终投递和豆包最终转写。Developer ID、公证、staple、解压后深层签名与 Gatekeeper 属于本轮已通过的产物验证，不替代这些实机路径。
- 本轮已启动 Developer ID 候选 App，并验证 HCI helper 授权进入 `packet_stream phase=ready result=authorized`。此前真实 A2854 已产生 PCM 与最终文字；当前改为无主动截尾的 closing/drain 构建仍需重新完成松键尾音和连续会话真机验收。
- 用户实测必须完成用例一至七和稳定功能回归，未完成项应逐项记录，不能用软件测试代替真机验收。
