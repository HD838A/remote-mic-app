# 阶段取消时的子进程 PID 竞态

## 证据与根因

PR #981 的 CI run 42747645795 在取消回归中超时。supervisor 已写入 started，后台命令 fork 后、CHILD_PID 赋值前收到 TERM 时，处理器看见空 PID，退出 143 但没有回收子进程。后台进程持有 stdout/stderr 管道，Python communicate 继续等待。

仓库外最小实验只在 fork 与赋值之间插入 0.5 秒延迟。本机 Python 3.14 同样复现 supervisor 已退出 143、管道仍开放，排除仅由 CI Python 3.15 引起的解释。简单 sleep 的确定性复现也排除复杂子进程树或纯 CI 负载。

## 修复

信号处理器先保存 CHILD_PID，空值时读取 shell 已登记的最后后台 PID。只接受正整数，再按既有进程树终止流程回收。状态仍为 cancelled，退出码仍为 143。

## 验证

新增回归测试读取生产 supervisor，仅在测试副本中扩大竞态窗口，确认后台任务已经启动后发送 TERM。旧实现 5 秒超时，修复后正常回收管道并记录 started/cancelled。测试副本保留在被忽略的隔离 fixture，完成后移到废纸篓。原有成功、失败、超时、取消和并发状态测试继续执行。
