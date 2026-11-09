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
