---
title: 苹果遥控器数据流释放时崩溃
subtitle: 同一串行队列同步等待自身
template: doc
theme: shadcn
---

## A 现象与证据

用户反馈开机后或运行一段时间后退出。
本记录只确认收到的这一次崩溃。

| 项目 | 证据 |
| --- | --- |
| 来源 | 用户提供的 crash-log.txt；未公开原始日志 |
| App | 1.10.0，build 230，ARM64 |
| 系统 | macOS 15.8.1，24H32 |
| 时间 | 2026-10-20；开机约 69 秒，App 启动约 43 秒 |
| 异常 | EXC_BREAKPOINT / SIGTRAP |
| 队列 | com.hd838a.RemoteMic.appleRemote.packetStream |
| 栈 | _dispatch_sync_f_slow → AppleRemotePacketLoggerClient.deinit |
| 系统原因 | dispatch_sync called on queue already owned by current thread |

没有同期运行日志。触发释放的上游原因未知。
无法确认其他几次退出是否具有相同原因。

## B 根因与最小修复

调查基线：d6b45c2ecbf497ebb2ee00e04cdee5ab5340c13e。

析构函数调用 stopSynchronously。
原实现无条件调用 stateQueue.sync。
对象在 stateQueue 中释放时，队列会同步等待自身。
libdispatch 检测到错误后终止进程。
崩溃栈与主线代码吻合，直接原因置信度高。

修复只增加实例独立的 DispatchSpecificKey。
当前已在该队列时，直接执行原有清理。
从其他队列释放时，仍同步执行清理。
连接取消、授权释放和状态重置的顺序保持不变。
析构继续禁止发出 stopped 事件。
清理完成后注销实例的队列标记。

## C 影响与日志边界

| 范围 | 影响 |
| --- | --- |
| 苹果遥控器 | 修复数据流客户端释放时的队列重入崩溃 |
| 公开构建 | 无需启用私有模块即可运行生命周期回归 |
| 实时语音 | 不改按键、采集、解码、尾包或输出路径 |
| 其他控制来源 | 不改 RC001、RC003、手机和手表路径 |
| 数据与权限 | 不改协议、授权规则、持久化或用户设置 |

逻辑链路为：停止请求 → 队列清理 → stopped 回调。
已有宿主记录 packet_stream 的失败原因和状态事件。
本次验证显式停止仍发出原事件，析构不新增终态。
未新增日志接口或逐包日志。
没有现场运行日志，不能补写触发停止的推测原因。
测试不连接系统蓝牙服务，也不申请真实授权。

## D 自动化验证

| 检查 | 结果 |
| --- | --- |
| 修复前同队列释放 | 失败；测试进程以信号 5 退出 |
| 修复后生命周期回归 | 5 项通过 |
| 公开配置测试 | 889 项、71 个 suite 通过；排除 BuildSigningTests |
| ARM64 Release 模块 | 编译通过，macOS 14 目标 |
| Intel Release 模块 | 编译通过，macOS 13 目标 |
| 静态检查 | diff、仓库边界、仓库治理通过 |
| 代码审查 | 核对队列身份、实例隔离、标记注销和清理顺序 |

定向命令：

```text
swift test --disable-keychain --filter AppleRemotePacketLoggerLifecycleTests
swift test --disable-keychain --skip BuildSigningTests
swift build --disable-keychain -c release --target AppleRemotePacketLogger --triple arm64-apple-macosx14.0
swift build --disable-keychain -c release --target AppleRemotePacketLogger --triple x86_64-apple-macosx13.0
```

回归覆盖同队列释放、异队列释放、共享队列和重复停止。
修复前先运行同队列释放用例，记录退出信号和栈。
修复后运行相同用例，确认原始错误消失。
本地签名环境测试未运行；完整双架构 App 构建交由 PR CI。

## E 待现场验收

自动化只证明内存对象和队列生命周期。
尚未验证用户设备、开机恢复、真实授权及长时间运行。
这是一项源码修复，不是安装包或发布验收。

1. 安装包含修复提交的正式签名候选包。
2. 保留苹果遥控器配置，重启 Mac。
3. 确认启动后不再出现相同崩溃栈。
4. 分别验证遥控器断连、重连、重试和正常退出。
5. 验证连续语音、正常松键尾字和再次录音。
6. 按原使用方式持续运行，并保留同期诊断日志。

任一步出现相同队列同步崩溃，即判定修复失败。
出现其他崩溃栈时，另行诊断，不归为同一根因。
