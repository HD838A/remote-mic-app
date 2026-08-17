# 正式版晋升 Runner 缺少 ripgrep

- 时间：2026-08-17
- 状态：已修复，等待下一次受保护晋升验证
- 影响范围：已有 macOS Pre-release 晋升为正式版的 GitHub Actions 流程
- 功能点：Release Guard、Stable Promotion 与 Latest 正式版状态
- 简单描述：手动把 `v1.8.25` 改为 Latest 后，Release Guard 因缺少正式晋升证明将其恢复为 Pre-release；随后自动发起的晋升工作流又因 Runner 没有 `rg` 立即失败。
- 原始记录：[失败的 Stable Promotion run 31988902061](https://github.com/HD838A/remote-mic-app/actions/runs/31988902061)

## 复现

现场事件顺序为：

1. 在 GitHub Release 页面手动把 `v1.8.25` 从 Pre-release 改为正式版。
2. Release Guard 检测到 Release 中不存在 `stable-promotion.json`，因此按既有安全规则将该版本恢复为 Pre-release，并发起正式晋升工作流。
3. `macOS Stable Promotion` run `31988902061` 完成 main 检出和候选解析后，执行 `./scripts/publish-release.sh promote` 立即失败。

本地使用不包含 Homebrew 工具的系统 PATH 可复现同一行为：

```bash
env PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  RELEASE_TAG=v1.8.25 \
  ./scripts/publish-release.sh promote
```

修复前输出为：

```text
./scripts/publish-release.sh:49: command not found: rg
PUBLIC_DOWNLOAD_CONCURRENCY must be between 1 and 8
```

## 日志与根因

run `31988902061` 在 `2026-08-17T02:44:20Z` 进入 `Promote unchanged candidate assets`，随后在 `publish-release.sh:49` 第一次调用 `rg` 时以退出码 1 结束。此前没有安装或检查 `ripgrep` 的步骤。

根因有两层：

- Stable Promotion 工作流直接调用广泛依赖 `rg` 的发布脚本，却没有像 Preview Candidate 和 Signed Release 工作流一样先检查 Runner 工具。
- `publish-release.sh` 自己虽然声明 `rg` 为必需命令，但依赖检查位于第一次 `rg` 调用之后，因此缺工具时输出了误导性的并发参数错误。

失败发生在读取、下载或修改 Release 资产之前，与 Apple 签名、公证、Tag、候选字节及版本内容无关。

## 修复

- `mac-stable-promote.yml` 在发布脚本前检查 `rg`；Runner 已有该工具时直接复用，只有缺失时才运行 `brew install ripgrep`，随后输出版本作为工具门禁证明。
- Stable Promotion Job 声明独立的 `mac-stable-release` Environment，用于正式晋升审批与权限隔离。该工作流不引用 Apple 签名 Secrets，也不会重新构建、签名或公证安装包。
- `publish-release.sh` 将全部必需命令检查移到第一次使用 `rg` 之前，使缺工具时明确输出 `Missing required command: rg`。
- 结构测试锁定工具检查早于晋升命令、脚本依赖检查早于首次 `rg` 调用、Environment 名称，以及工作流不得引用 Secrets。

## 验证边界

自动化验证覆盖工作流结构、Shell 语法、无 `rg` PATH 下的非法并发参数拒绝、有效晋升预检缺少 `rg` 时的明确失败信息，以及现有发布脚本回归。此次修复不会触发 Stable Promotion、Tag 或 Release 修改；真实受保护 Environment 审批、公开资产复验、`stable-promotion.json` 上传和 Latest 状态切换，必须在合并后由获授权的发布会话对既有 Pre-release 执行一次正式晋升验证。
