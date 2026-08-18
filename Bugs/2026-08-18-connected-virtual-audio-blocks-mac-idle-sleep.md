# 遥控器持续连接时虚拟音频阻止 Mac 自动休眠

- 时间：2026-08-18
- 状态：候选修复完成，等待真实休眠与 `pmset` 验收
- 影响范围：macOS 1.8.3 及当前 `main`；已选择 `MiRemoteV 2ch` 且遥控器持续连接的用户
- 功能点：系统休眠通知、蓝牙连接生命周期、虚拟音频输出
- 简单描述：遥控器处于 ready 状态时，无线麦SayAll.app持续运行 MiRemoteV 2ch 音频 IO，CoreAudio 因此持有 `PreventUserIdleSystemSleep`，阻止 Mac 自动进入空闲休眠。
- 原始记录：用户提供的 `runtime.log`、`pmset -g assertions` 和“选择不输出语音后恢复”的截图；原始资料保存在共享 Bug 目录，不复制设备身份或其他现场信息到仓库。

## Observations

- 2026-08-18 11:28:08（北京时间），macOS 1.8.3 启动后立即配置 `MiRemoteV 2ch`，日志显示 `engine_running=true`。
- 11:28:09 遥控器进入 BLE ready；之后到 13:32:45 之间没有语音流，但音频引擎一直保持运行。
- 13:22:06 执行 `pmset -g assertions` 时，`coreaudiod` 为无线麦SayAll.app进程持有 `com.apple.audio.MiRemoteV2ch_UID.context.preventuseridlesleep`，持续时间为 01:53:57。
- 按持续时间倒推，断言约在 11:28:09 创建，与音频引擎启动只差约一秒。
- 13:32:45 选择“不输出语音”后，日志立即变为 `engine_running=false`；用户同时确认这样设置后不再出现问题。
- `PreventUserIdleSystemSleep` 只证明自动空闲睡眠被推迟，不代表菜单中的手动睡眠或合盖一定会被阻止。
- 当前代码没有 `IOPMAssertion`、`ProcessInfo.beginActivity`、`caffeinate` 或其他主动防休眠调用。
- 2026-08-11 的断连释放修复只覆盖“最后一只 ready 遥控器断开”；本次遥控器一直在 Mac 旁边，因此不会触发该释放路径。

## Hypotheses

### H1：持续运行虚拟音频 IO 触发 CoreAudio 防空闲休眠断言（ROOT HYPOTHESIS）

- Supports：断言资源、创建进程、持续时间与 `AVAudioEngine` 启动时间完全对应；选择“不输出语音”会停止同一引擎。
- Conflicts：无。
- Test：比较音频引擎启动时间与 `pmset` 断言创建时间，并在停止音频 IO 后核对引擎状态；现场资料已经完成前两项，修复后仍需在真实 Mac 上确认断言消失。

### H2：无线麦SayAll.app主动调用了防休眠 API

- Supports：现象看起来像 App 主动禁止睡眠。
- Conflicts：全仓库没有任何相关电源断言 API；`pmset` 显示断言由 `coreaudiod` 以音频资源名创建。
- Test：静态搜索电源管理调用；已否定。

### H3：蓝牙连接本身长期阻止睡眠

- Supports：同一份 `pmset` 输出中存在短时 `bluetoothd` 断言。
- Conflicts：蓝牙断言只持续约 20 秒，而 CoreAudio 断言持续 01:53:57，并与 App 音频引擎启动时间一致。
- Test：比较两个断言持续时间与资源归属；已否定为主要原因。

### H4：外接磁盘或其他系统服务是主要原因

- Supports：现场同时存在 `ExternalMedia`、Handoff 和 WindowServer 断言。
- Conflicts：这些断言与 MiRemoteV 2ch 无关；选择“不输出语音”只改变无线麦SayAll.app的音频引擎，却能解除用户观察到的问题。
- Test：停止无线麦SayAll.app音频 IO后单独复查 `pmset`；现有时间线否定其为本 Bug 根因，仍保留真机复核边界。

## Experiment

- 现场日志中的引擎启动时间为 11:28:08；13:22:06 的 CoreAudio 断言持续 01:53:57，倒推创建时间为 11:28:09。两条独立日志误差约一秒，确认断言随虚拟音频 IO 创建。
- 选择“不输出语音”时，生产日志从 `engine_running=true` 立即变为 `engine_running=false`，确认停止 App 音频 IO是解除占用的最小变量。
- 当前开发 Mac 不是反馈用户的实际测试 Mac；修复前无法在本机替代用户完成相同 `pmset` 真机复现。

## Root Cause

当前虚拟音频生命周期把“存在 ready 蓝牙遥控器”等同于“必须持续运行音频 IO”；遥控器长时间连接但没有语音时，CoreAudio 仍为 MiRemoteV 2ch 持有防空闲休眠断言。

## Fix

- 监听屏幕休眠/唤醒、用户会话锁定/解锁、系统即将睡眠/已经唤醒六类 `NSWorkspace` 事件。
- 用原因集合记录 `screen_sleeping`、`session_inactive`、`system_sleeping`，避免屏幕先亮但会话仍锁定时过早恢复音频。
- 屏幕休眠、锁屏或系统睡眠时，如果没有正在进行的蓝牙语音、手机/Watch 语音或测试音，则排空缓冲并停止虚拟音频引擎；遥控器保持 BLE ready 不再单独维持音频 IO。
- 如果休眠事件到达时正在传输语音或播放测试音，不打断当前音频；活跃源结束后再自动释放。
- 最后一个暂停原因解除后，如遥控器仍 ready 且用户仍选择原虚拟设备，则自动重新绑定；暂停期间首次按下语音键也会触发恢复兜底。
- 如果音频仍在排空而系统已唤醒、遥控器重新 ready 或新语音/测试音开始，新需求会显式取消旧释放及其排空回调，避免旧回调冲掉唤醒后的第一段音频。
- 如果释放前由无线麦SayAll.app管理的虚拟设备是系统默认输入，先切换到合适的实体输入；恢复时仅当默认输入仍是该受管回退设备才恢复虚拟输入，避免覆盖用户在休眠期间手动作出的选择。
- 新增 `SYSTEM AUDIO`、`AUDIO RELEASE`、`AUDIO REBIND`、`AUDIO DEFAULT_INPUT` 诊断日志，包含事件、暂停原因、活跃音源、ready 遥控器数量、释放代次、取消原因、缓冲数量及引擎/设备状态，可区分未收到系统事件、释放被延迟、被新需求取消、停止失败或恢复失败。

## Validation

- `swift test --filter VirtualAudioConnectionLifecycleTests`：10 个测试通过，覆盖正常连接、系统暂停、活跃语音保护、手机/Watch/测试音、重叠事件和重复事件。
- `swift test --skip-build --filter VoiceFnTapSessionControllerTests`：8 个测试通过。
- `swift test --skip-build --filter BluetoothLifecycleTests`：6 个测试通过。
- `swift test`：20 个测试套件、230 个测试全部通过。
- `./script/build_and_run.sh --verify`：Release 构建、App 组装和本地签名校验通过；仅出现修改前已存在的 macOS 14 `onChange` 弃用警告。
- `git diff --check`：通过。
- 尚未在反馈用户的 Mac 或等价真实环境执行真实 MiRemoteV 2ch、真实遥控器、自动显示器休眠、自动系统休眠及 `pmset -g assertions` 验收，因此当前只能标记为候选修复，不能确认 CoreAudio 断言已在真机消失。
