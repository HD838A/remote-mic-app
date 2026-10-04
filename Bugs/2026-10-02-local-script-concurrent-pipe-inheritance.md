# 本地脚本并发管道继承（开发期回归）

- 范围：统一按键源码分支的新增脚本执行器，尚未发布。
- 复现：并行执行 `printf`、大量输出、`sleep 30 & wait` 的 Swift Testing 用例；
  首轮脚本输出管道迟迟没有 EOF，取消/超时用例超过预期 3 秒；串行或单例运行正常。
- 日志：私有 worktree `combination-tests.log` 首轮超时断言失败；
  只打印测试名与耗时，没有源码/用户输出进入运行日志。
- 根因实验：检查 posix_spawn 文件描述符策略，子进程继承其他并发用例的写端，
  使已退出父进程的管道无法关闭；新增 CLOEXEC_DEFAULT 后原并发用例通过。
- 修复：spawn flags 同时使用 `POSIX_SPAWN_CLOEXEC_DEFAULT` 和 `POSIX_SPAWN_SETPGROUP`；
  取消先 TERM，300ms 后 KILL，父进程提前退出时仍 KILL 取消中的组，再释放组标识。
- 复验：私有 `swift test --disable-keychain` 的脚本用例并发通过，覆盖成功、非零、
  大量输出、AppleScript、未授权、超时、取消和忽略 TERM 子进程。
- 边界：只证明新增进程执行器，不替代真实 App Automation 权限、遥控器和语音验收。
