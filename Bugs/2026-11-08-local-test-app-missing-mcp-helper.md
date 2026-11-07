# 本地测试 App 缺少回眸 MCP Helper

在 macOS Apple Silicon 检查本地 Build 308 时，`SayAll.app/Contents/Helpers/SayAllMCP` 不存在。系统安装位置中的 App 包含该可执行文件。旧本地打包入口只复制主程序和资源，也没有为 SwiftPM 传入 `--disable-keychain`。

本地入口改用项目原生打包器，再在产物上递增字符串类型的构建号，写入来源和工作区状态并重新签名。Build 309 曾因测试脚本把构建号写成整数而在 Metal 初始化时崩溃。改回字符串后，Build 310 启动成功，可打开回眸。Developer ID、嵌套签名及项目包校验通过，包内 Helper 用合成数据通过工具发现、筛选分页和撤销验证。

检查命令包括 `zsh -n scripts/package-local-test-app.sh`、`scripts/verify-app.sh` 和 `codesign --verify --deep --strict`。此次验证覆盖 Apple Silicon、本地包与 MCP Helper。
