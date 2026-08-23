# 不同版本的无线麦可同时运行

- 时间：2026-08-24
- 状态：修复完成，等待两个正式签名版本的真实启动与更新验收
- 影响范围：macOS；同一用户安装或保留多个 Bundle ID 为 `com.hd838a.RemoteMic` 的历史版本
- 功能点：App 启动、蓝牙、虚拟音频、HID 映射、登录启动与更新
- 简单描述：启动入口没有实例互斥，两个版本会同时初始化同一套蓝牙、音频和 HID 资源。

## 复现

当前机器同时保留了多个历史版本。`~/Library/Logs/RemoteMic/runtime.log` 中可稳定找到嵌套生命周期：

- `2026-08-17T01:03:28Z APP START version=1.8.5`
- 未出现对应 `APP STOP` 前，`2026-08-17T01:04:33Z APP START version=1.8.25`
- 两个实例都重新执行 HID、蓝牙和虚拟音频初始化
- `2026-08-17T01:12:30Z` 连续出现两条 `APP STOP`

另一次记录中，`1.9.8` 在 `2026-08-23T15:42:32Z` 和 `17:00:20Z` 各启动一次，随后在 `17:00:58Z` 与 `17:02:47Z` 分别停止。旧日志没有 PID，不能把中间每一行无歧义地归属到某个进程，但嵌套的启动和停止边界足以确认并发实例存在。

正常边界应为：同一 macOS 用户同一时间只运行一个无线麦实例；再次打开任一包含守卫的新版本时，应激活已运行实例，而不是再次启动音频、BLE 或 HID。

## 日志结论与根因

`Sources/RemoteMic/RemoteMicApp.swift` 的截图渲染专用入口返回后，原实现直接创建 `NSApplication.shared` 与 `RemoteMicAppDelegate`。`applicationDidFinishLaunching` 随后启动音频、蓝牙与 HID，但启动前没有：

- 按 Bundle ID 查询同用户已运行 App；
- 用户级文件锁或其他可跨进程的原子互斥；
- 已有实例的激活路径。

登录启动使用 `SMAppService.mainApp`，只负责请求系统启动主 App，不提供单实例保证。Sparkle 和 PKG 的既有更新流程会在替换前停止宿主，也不能覆盖用户手动打开两个 App 副本的场景。

## 修复

1. 在所有截图渲染专用入口之后、创建 `NSApplication.shared` 之前，在 `~/Library/Application Support/RemoteMic/.app-instance.lock` 上竞争非阻塞排他 `flock`；锁先裁决两个新版本几乎同时启动的竞态，避免双方互相看到尚未完成启动的进程后同时退出。
2. 获取锁后按正式 Bundle ID 查询已经完成启动的历史实例；命中后激活其窗口并退出当前启动。未获取锁的并发启动直接让行，并尽力激活锁持有者。
3. 锁文件描述符持有到 App 主运行循环结束；正常退出或崩溃都会由内核释放锁，不能把“锁文件存在”误当作实例仍运行。
4. 锁目录或锁文件因本地权限异常无法使用时，向标准错误输出非敏感原因并保持 fail-open，避免一次文件系统故障让 App 永久无法启动。

截图生成入口不获取实例锁，CI 和文档截图任务仍可独立运行。

## 验证

自动化：

```bash
swift test --filter ApplicationInstanceGuardTests
swift test --filter LoginItemServiceTests
swift test
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh dist/SayAll.app
```

`ApplicationInstanceGuardTests` 覆盖首个持有者成功、第二个持有者被拒绝，以及首个持有者释放后可重新获取。还需在独立测试用户中使用两个包含该修复的不同签名版本，分别验证正反启动顺序、`open -n`、直接运行可执行文件、登录项启动和 Sparkle 更新；每个场景都应只存在一个同 Bundle ID 进程。

## 验证边界与风险

- 自动化锁测试不能替代 LaunchServices、真实登录项和真实 Sparkle 更新验收。
- 新版本在历史旧版已经运行时会识别旧版并退出；两个都包含守卫的新版本可双向互斥。
- 历史旧版自身没有守卫。如果先运行新版本、再直接启动不含修复的历史旧版，旧版仍可能短暂或持续启动。首个修复不主动终止其他进程，以免在用户尚未保存设置或正在语音时强制结束 App；该过渡边界必须通过安装器清理旧副本和后续版本普及逐步消除。
