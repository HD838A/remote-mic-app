# 发布流程私有源码边界

## 错误证据与根因

官方 staging 的附件凭据缺失分支会调用私有构件编译器。执行该生产 shell 片段，并以成功退出的合成编译器替代真实编译器，观察到 canary 直接进入 stdout。公开仓库的手动私有集成 CI 同样直接编译私有源码。

普通打包默认选择 auto。注入私有网络失败时，auto 打包失败，而 public 模式直接返回公开配置。默认路径因此依赖私有网络。

这些实验确认了错误分支。调查期间没有运行真实私有编译器，也没有创建候选 Tag 或 Pre-release。

## 修复

- 普通打包默认 public，显式私有输入保留本机集成能力。
- 分发渠道只消费固定 Tag 的持久二进制附件，读取失败立即停止。
- 用不含代码 diff 的只读元数据验证 annotated Tag、主线祖先与根清单，并绑定构件来源 Commit。二进制消费者保持明确选定的冻结 Tag。
- 私有源码集成测试迁入私有仓库，公开入口保留迁移说明。
- 上传前扫描 ZIP、安装包与嵌套归档，恢复和 publication 使用相同检查。

## 验证入口

- `python3 scripts/test-private-platform.py`
- `scripts/test-macos-release-flow.sh`
- `swift test --disable-keychain --filter BuildSigningTests`
- `scripts/verify-release-dependency-pins.sh`
- `python3 scripts/prepare-private-platform.py check-release`
- `python3 scripts/verify-release-contents.py <公开资产目录>`

自动化覆盖来源错误、缺权限、公开默认模式、源码回退、嵌套源码与真实安装包 payload。Developer ID、公证、真实 Sparkle 安装、硬件和第三方工具流程分别记录，发布流程检查不能替代这些结果。

## 2026-11-10 阶段诊断复验

staging Run 42669096984 的私有二进制准备通过，签名步骤在运行约 456 秒后失败，Artifact 清单为空。公开日志只有统一失败标记，无法确认编译、签名、公证或资产校验中的具体失败阶段。

生产 shell 片段回归确认两项诊断缺口。子命令退出码 7 被改写为 1；supervisor 的非敏感控制状态也被重定向进详细日志。原签名失败的根因仍待受保护重现，耗时接近构建预算只能作为超时假设。

修复后，现有 supervisor 单独追加结构化控制记录。两架构并行时每条记录使用单次 append。公开报告验证记录格式，并保留原退出码、超时和取消状态。私有子进程 canary 与伪造的阶段文本均保存在详细日志中。

定向回归覆盖成功、失败、重试、超时、取消、并行追加和异常状态文件。签名候选仍需重新完成签名、公证、内容检查与真实 Sparkle 验收。
