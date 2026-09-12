# SwiftPM 反复请求 GitHub 钥匙串权限

## 复现

在 macOS 本地运行未传入 `--disable-keychain` 的 SwiftPM 构建或测试命令。依赖解析或下载 Sparkle 二进制 artifact 时，系统弹出“swift-package 想要使用你储存在钥匙串的 github.com 中的机密信息”。

现场截图确认弹窗主体为 Xcode 工具链中的 `swift-package`。登录钥匙串中存在历史 `github.com` 网络密码记录，而 Git 源码依赖已经通过 GitHub CLI 凭据助手正常访问。

## 日志与边界

弹窗截图提交时，对应 SwiftPM 进程已经退出，因此无法从当前进程树恢复当次完整命令行；macOS 统一日志也没有留下可用的弹窗事件。仓库检查确认正式 App、项目自检和 RC003 测试包脚本仍包含未禁用钥匙串的 SwiftPM 命令。

## 根因

SwiftPM 在 macOS 默认启用钥匙串凭据搜索。Git 使用 GitHub CLI 凭据助手并不能阻止 SwiftPM 的 HTTP 二进制 artifact 下载器独立扫描钥匙串。此前仅修改单个构建脚本，后续主分支更新覆盖了该参数，其他本地 SwiftPM 入口也未受保护。

## 修复

- 为 `scripts/build-app.sh` 的构建和 `--show-bin-path` 命令加入 `--disable-keychain`。
- 为 `scripts/test.sh` 的 SwiftPM 构建加入 `--disable-keychain`。
- 为 `Testing/build_rc003_preview.sh` 的构建和 `--show-bin-path` 命令加入 `--disable-keychain`。
- 在 `AGENTS.md` 中规定本地 SwiftPM 命令必须禁用钥匙串，防止代理手动验证和后续脚本再次引入弹窗。
- 在既有 macOS 发布流程测试中增加静态门禁；任一本地构建入口丢失该参数时 CI 立即失败。

没有读取、修改或删除钥匙串中的凭据；GitHub 私有源码依赖继续通过现有 Git 凭据助手访问。

## 验证

- Shell 语法检查必须通过。
- 使用全新持久 scratch/cache 运行 `swift package resolve --disable-keychain`，验证私有源码依赖和 Sparkle 二进制 artifact 均能下载。
- 运行项目自检入口，确认其 SwiftPM 阶段成功且没有请求钥匙串权限。
- 检查所有本地可执行 Shell 入口，确认 SwiftPM 调用均包含 `--disable-keychain`。

自动化只能证明这些命令不会主动扫描钥匙串；Xcode 图形界面自行发起的包解析不受仓库 Shell 参数控制。
