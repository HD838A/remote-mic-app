# 预发布候选工作流依赖 Runner 未安装的 rg

- 时间：2026-08-11
- 状态：已修复
- 影响范围：macOS 公开预发布候选分支的 GitHub Actions 校验
- 功能点：预发布候选来源与发布说明门禁
- 简单描述：候选分支在本地校验通过，但 GitHub macOS runner 因未安装 `rg` 而错误判定发布说明缺失。
- 原始记录：[macOS Preview Candidate run 31458426481](https://github.com/HD838A/remote-mic-app/actions/runs/31458426481)

## 复现

触发条件是从符合命名规则的 `release/pre-vX.Y.Z` 分支运行 `scripts/verify-preview-branch.sh`，且执行环境的 `PATH` 中没有 `rg`。`v1.8.8` 候选在 GitHub Actions 中稳定失败；本地使用系统命令限定 PATH 也能复现：

```bash
env PATH=/usr/bin:/bin:/usr/sbin:/sbin ./scripts/verify-preview-branch.sh
```

错误结果为脚本报告 `command not found: rg`，随后把真实存在的 `1.8.8` 发布说明误报为缺失。正常边界是候选分支包含正确中英文版本条目时应继续通过门禁。

## 日志与根因

Actions 日志在 `Validate candidate branch provenance` 步骤的第 127 行首先出现 `command not found: rg`，随后才出现发布说明缺失提示。对应代码直接使用 `rg` 检查变更文件、版本标题和疑似明文凭据，但工作流没有安装 ripgrep，脚本也没有把它声明为依赖。

根因是候选门禁错误依赖本机额外安装的命令，而不是发布说明内容或候选分支来源异常。

## 修复

仅把候选门禁中的 `rg` 调用替换为 macOS runner 自带的 `/usr/bin/grep`：固定字符串检查使用 `grep -F`，凭据模式检查使用 `grep -E`。没有修改候选分支规则、版本比较、允许文件列表或凭据检测模式。

## 验证

已完成以下验证：

- `/bin/zsh -n scripts/verify-preview-branch.sh` 通过。
- 在 `v1.8.8` 候选分支临时应用同一修复后，使用 `env PATH=/usr/bin:/bin:/usr/sbin:/sbin ./scripts/verify-preview-branch.sh` 重新执行原始复现，结果由退出码 1 变为退出码 0，并输出 `PREVIEW BRANCH PASS`。
- 验证后已撤销候选分支上的临时改动，候选工作树保持干净；正式修复只提交到独立修复分支。

仍需由修复合入后的 GitHub `macOS Preview Candidate` 工作流确认托管 runner 边界。该问题只涉及 CI 发布门禁，不涉及 App、蓝牙、音频、系统权限或真实硬件行为。
