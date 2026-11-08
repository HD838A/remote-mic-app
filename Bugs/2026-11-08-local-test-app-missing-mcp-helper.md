# 本地测试 App 缺少回眸 MCP Helper

在 macOS Apple Silicon 检查本地 Build 308 时，`SayAll.app/Contents/Helpers/SayAllMCP` 不存在。系统安装位置中的 App 包含该可执行文件。旧本地打包入口只复制主程序和资源，也没有为 SwiftPM 传入 `--disable-keychain`。

本地入口改用项目原生打包器，再在产物上递增字符串类型的构建号，写入来源和工作区状态并重新签名。Build 309 曾因测试脚本把构建号写成整数而在 Metal 初始化时崩溃。改回字符串后，Build 310 启动成功，可打开回眸。Developer ID、嵌套签名及项目包校验通过，包内 Helper 用合成数据通过工具发现、筛选分页和撤销验证。

检查命令包括 `zsh -n scripts/package-local-test-app.sh`、`scripts/verify-app.sh` 和 `codesign --verify --deep --strict`。此次验证覆盖 Apple Silicon、本地包与 MCP Helper。

## 替换旧包失败

在隔离目录注入写入失败时，旧 App 移入废纸篓后无法恢复，脚本仍改装到备用位置并报告成功。提前退出也会在安装目录留下暂存目录。根因是恢复失败和普通安装失败共用返回值，且只有成功分支处理暂存目录。

脚本现在在恢复失败时报告旧包位置并退出。旧包成功恢复或尚未移动时，仍可使用备用安装路径。暂存目录在完成或退出时均移入废纸篓。隔离验证覆盖主目录正常安装、暂存复制失败、替换失败但恢复成功，以及替换和恢复均失败。最后一种情况保留旧包并跳过备用安装。

另用未设置 `RELEASE_VARIANT` 的环境验证 Intel 参数传递。父脚本加载 `release-variant.sh` 后导出 `intel`，子脚本选择同一个 `dist/intel` 目录。该验证覆盖脚本参数，Intel Mac 的完整构建、签名和安装待现场执行。

本次原生打包候选需要清单对应的私有构件和 Developer ID 签名，才能包含 Siri Remote 语音所需的签名组件。仓库对本地测试包的签名规则需要独立治理确认。
