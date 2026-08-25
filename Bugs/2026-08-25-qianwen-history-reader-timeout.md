# 千问历史读取进程无超时可能阻塞微信回眸

- 时间：2026-08-25
- 状态：已修复，自动化与双架构 Release 编译通过，等待安装包微信回眸复验
- 影响范围：微信回眸读取
- 简单描述：读取千问本地历史的 Helper 如果不退出，父进程会永久等待，当前微信回眸停止轮询，后续语音会话还可能再次启动读取进程。

## 复现、日志与根因

- 受控复现使用忽略 `TERM` 的子进程模拟不退出的 Helper；旧实现会在 `waitUntilExit()` 永久等待。
- 该路径没有可用的用户现场日志；代码审计确认 completion 永远不返回时，协调器无法安排下一轮或执行总超时关闭。
- 根因是 `QianwenHistoryReader.readLatest` 只有父级 10 秒轮询预算，没有约束单次外部进程的硬超时和终止路径。

## 修复

- Reader 使用 3 秒硬超时；正常退出后才解析标准输出。
- 超时后先发送终止，100 毫秒后仍运行才强制结束；启动失败或超时都返回空结果，由现有回眸轮询继续失败关闭。
- 保留现有串行轮询，不新增通用 Process 框架或其他功能。

## 验证

- `xcrun swift test --scratch-path <临时目录> --cache-path <临时目录> --disable-keychain --disable-netrc`：405 个测试、37 个测试套件通过。
- `SKIP_SWIFT_PACKAGE_BUILD=1 ./scripts/test.sh`：self-test 43/43 通过。
- `xcrun swift build -c release --triple arm64-apple-macosx ...`：Build complete。
- `xcrun swift build -c release --triple x86_64-apple-macosx ...`：Build complete。
- 自动化覆盖成功解码且 completion 只调用一次、启动失败、超时失败关闭、忽略普通终止时强制结束，以及 reader 未完成前不启动下一次轮询。

## 验证边界

- 自动化使用受控子进程验证超时与强制结束，不代表千问未来版本的私有运行库和历史格式保持兼容。
- 仍需用最终签名包在微信连续完成至少 3 次语音，确认每次均保存回眸、没有残留 `QianwenHistoryReader` 进程，普通 App 回眸不受影响。
