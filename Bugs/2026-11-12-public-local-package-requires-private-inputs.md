# 公开本地打包入口强制要求私有输入

- 时间为 2026-11-12。
- 状态为公开本地打包与启动已验证，远端 CI 待完成。
- 范围为 macOS 公开开发自用的统一本地打包入口。

## 错误证据与触发条件

只有公开仓库权限、未设置私有源码或构件路径时，执行 `scripts/package-local-test-app.sh`，原实现于第 13 行报告 `SAYALL_PRIVATE_SOURCE_ROOT: Set the private platform source root` 并退出 1。失败发生在编译之前。

PR #921 的公开 CI 已通过 Swift 测试、双架构 Release 和 `build-app.sh` 的公开 App 校验。现有证据支持入口前置条件冲突。实际 GUI 启动需独立验证。

## 根因验证

- 2026-11-02 新增本地打包脚本时即强制私有源码，随后规定为统一入口。
- 公开构建规则要求零私有权限可编译和本地运行，CI 却仅验证另一条公开构建入口。
- 2026-11-08 的完整测试包规则进一步要求私有预构件和 Developer ID，公开开发自用缺少适用模式。
- 清空私有输入执行原入口可重复失败。修复后相同模式前置检查通过；显式 required 缺件仍失败。

## 最小修复

- 统一入口无私有输入时默认 public，既有私有输入调用默认 required，显式模式按输入校验。
- public 允许构建者本机自用的 ad-hoc 或 Developer ID 签名，记录 public 渠道、来源提交、dirty 与构建号，复用原生资源组装和包校验。
- required 继续验证固定私有构件与源码对应关系、Developer ID 和预期 Team ID。缺件、构件不一致或签名失败即停止。
- 公开渠道不传入私有准备器的发行渠道参数，也不触发完整集成诊断配置要求。
- CI 清空私有路径，执行统一入口，再启动精确产物并在有界时间内确认对应进程仍存活。
- 规则边界由独立治理 PR #1018 同步。向他人分发继续执行签名、公证与适用的下载复验。

## 验证与边界

- `swift test --disable-keychain --filter localPackage` 的两项测试、十组参数通过，覆盖 public/default、required 缺件、私有输入模式、公私输入冲突，以及原有 Tag/本地提交/构件不一致校验。
- 实际公开 Apple Silicon Release 打包通过，`verify-app.sh`、`codesign --verify --deep --strict` 通过。Build 333 的 public 渠道、私有构件 false、来源提交和 dirty=true 与构建树一致。安装到独立本地目标后，使用 `open -n` 启动该包，精确可执行路径的进程持续存活三秒，随后退出测试进程。
- 进程启动只证明启动边界，真实权限、小米遥控器与目标语音工具仍须实机验收。

- 本轮 BuildSigningTests 29 项通过，包含完整发布控制面夹具。其余全量 Swift Testing 1,383 项 / 100 suites 和 XCTest 4 项通过，仅跳过上述已单独通过的发布夹具。`actionlint`、shell 语法、治理、边界与 diff 检查通过。
