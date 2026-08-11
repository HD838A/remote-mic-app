# 预发布候选工作流依赖 Runner 未安装的 rg

- 时间：2026-08-11
- 状态：已修复
- 影响范围：macOS 公开预发布候选分支的 GitHub Actions 校验
- 功能点：预发布候选来源与发布说明门禁
- 简单描述：候选分支在本地校验通过，但 GitHub macOS runner 因未安装 `rg` 而错误判定发布说明缺失。
- 原始记录：[首次失败 run 31458426481](https://github.com/HD838A/remote-mic-app/actions/runs/31458426481)、[后续失败 run 31458857425](https://github.com/HD838A/remote-mic-app/actions/runs/31458857425)、[修复通过 run 31459320898](https://github.com/HD838A/remote-mic-app/actions/runs/31459320898)

## 复现

触发条件是从符合命名规则的 `release/pre-vX.Y.Z` 分支运行 `scripts/verify-preview-branch.sh`，且执行环境的 `PATH` 中没有 `rg`。`v1.8.8` 候选在 GitHub Actions 中稳定失败；本地使用系统命令限定 PATH 也能复现：

```bash
env PATH=/usr/bin:/bin:/usr/sbin:/sbin ./scripts/verify-preview-branch.sh
```

错误结果为脚本报告 `command not found: rg`，随后把真实存在的 `1.8.8` 发布说明误报为缺失。正常边界是候选分支包含正确中英文版本条目时应继续通过门禁。

## 日志与根因

首次 Actions 日志在 `Validate candidate branch provenance` 步骤的第 127 行首先出现 `command not found: rg`，随后才出现发布说明缺失提示。把该门禁改为系统 `grep` 后，第二次工作流已经通过候选来源、Swift 测试、自测、Release 构建和 App 构建，但在 `Verify candidate App structure` 的 `scripts/verify-app.sh:76` 再次因 `rg` 不存在而以 127 退出。

根因是预发布工作流没有安装仓库发布验证脚本声明并广泛使用的 ripgrep。本机已安装 `rg`，所以完整链路只在 GitHub 托管 runner 上暴露；发布说明内容、候选分支来源和 App 构建本身均无异常。

## 修复

修复分为两个最小边界：

- 候选来源门禁改用 macOS runner 自带的 `/usr/bin/grep`，避免基础来源校验依赖额外工具。
- 预发布工作流在所有验证前显式执行 `command -v rg >/dev/null || brew install ripgrep`，满足 `verify-app.sh` 及后续发布验证脚本的既有依赖。

没有修改候选分支规则、版本比较、允许文件列表、凭据检测模式、App 验证规则或打包行为。

## 验证

已完成以下验证：

- `/bin/zsh -n scripts/verify-preview-branch.sh` 通过。
- 在 `v1.8.8` 候选分支临时应用同一修复后，使用 `env PATH=/usr/bin:/bin:/usr/sbin:/sbin ./scripts/verify-preview-branch.sh` 重新执行原始复现，结果由退出码 1 变为退出码 0，并输出 `PREVIEW BRANCH PASS`。
- 验证后已撤销候选分支上的临时改动，候选工作树保持干净；正式修复只提交到独立修复分支。

修复后的 GitHub `macOS Preview Candidate` run 31459320898 已在托管 runner 上完整通过工具安装、候选来源校验、Swift 测试、项目自测、Release 构建、App 构建、App 结构验证、CI 候选包打包和上传。该问题只涉及 CI 发布门禁，不涉及 App、蓝牙、音频、系统权限或真实硬件行为。
