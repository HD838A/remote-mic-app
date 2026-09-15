#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'repository governance check failed: %s\n' "$1" >&2
  exit 1
}

require_heading() {
  local file="$1"
  local heading="$2"
  grep -Fqx -- "$heading" "$file" || fail "$file is missing $heading"
}

require_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file is missing required rule: $text"
}

[[ -f BRANCH_MANAGEMENT.md ]] || fail 'BRANCH_MANAGEMENT.md is missing'
[[ -f AGENTS.md ]] || fail 'AGENTS.md is missing'
[[ -f DOCUMENTATION.md ]] || fail 'DOCUMENTATION.md is missing'
[[ -f RELEASING.md ]] || fail 'RELEASING.md is missing'

for heading in \
  '## 标准功能与 Bug 流程' \
  '## PR 创建门禁' \
  '## 工作区状态审计' \
  '## TODO-only 工作流程' \
  '## 独立工作项提交边界' \
  '## 规范变更隔离与防护'; do
  require_heading BRANCH_MANAGEMENT.md "$heading"
done

require_text BRANCH_MANAGEMENT.md '所有 TODO-only 记录统一使用长期分支 `codex/todo_list`'
require_text BRANCH_MANAGEMENT.md '立即 Push 并创建只包含该 TODO commit、目标为 `main` 的 PR'
require_text BRANCH_MANAGEMENT.md '每个 PR 必须且只能对应一项独立、可审查的功能'
require_text BRANCH_MANAGEMENT.md '发现 `ahead/behind`、未跟踪文件、未提交改动或已合入但仍保留的旧 worktree 时'
require_text BRANCH_MANAGEMENT.md '任何单个待提交文件超过 5 MB 时'
require_text BRANCH_MANAGEMENT.md '相关提交信息中包含 `[governance-change]`'
require_text BRANCH_MANAGEMENT.md '`Repository governance` 必须配置为 `main` 的 Required status check'
require_text BRANCH_MANAGEMENT.md 'PR 默认使用 GitHub 的普通 Merge（保留合并提交）'
require_text BRANCH_MANAGEMENT.md '确认后必须在 PR 正文记录明确的批准来源'
require_text BRANCH_MANAGEMENT.md '自动化 Agent 不得在缺少该确认时自行将其标记 Ready、批准或合入'
require_heading AGENTS.md '## 规范层级与文档边界'
require_heading AGENTS.md '## 任务范围与等待治理'
require_text AGENTS.md '分析、审查、诊断或状态查询默认只做只读检查并给出证据和结论'
require_text AGENTS.md '当前任务之外的优化、重构、规范调整或历史清理必须拆成独立工作项'
require_text AGENTS.md '禁止使用无法可靠收回控制权的交互式 CI 等待命令'
require_text RELEASING.md '只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。'
require_text RELEASING.md '已撤回、删除或从未公开的版本不进入 App 内版本历史。'
require_heading DOCUMENTATION.md '# 项目文档导航'
require_text DOCUMENTATION.md "rg --files -g '*.md' | sort"
require_text AGENTS.md '[`DOCUMENTATION.md`](DOCUMENTATION.md)'
require_text README.md '[项目文档导航](DOCUMENTATION.md)'
[[ "$(grep -Foc -- '[项目文档导航](DOCUMENTATION.md)' README.md)" == 1 ]] || \
  fail 'README must contain exactly one stable documentation navigation link'
if grep -Fq -- '## 规范文件索引' README.md; then
  fail 'README must not embed the full specification index'
fi
while IFS= read -r document_path; do
  [[ -n "$document_path" ]] || continue
  require_text DOCUMENTATION.md "$document_path"
done < <(find feature -type f \( -name PRODUCT_SPEC.md -o -name 'platform-*.md' \) -print | sort)
while IFS= read -r document_path; do
  [[ -n "$document_path" ]] || continue
  require_text DOCUMENTATION.md "$document_path"
done < <(find Testing -maxdepth 1 -type f -name '*Contract.md' -print | sort)

base_ref="${1:-}"
if [[ -n "$base_ref" && "$base_ref" != 0000000000000000000000000000000000000000 ]]; then
  git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 || fail "base commit is unavailable: $base_ref"

  governance_changed=false
  scope_violation=false
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      AGENTS.md|BRANCH_MANAGEMENT.md|FEATURE_DEVELOPMENT.md|.github/PULL_REQUEST_TEMPLATE.md|.github/workflows/repository-governance.yml|scripts/verify-repository-governance.sh)
        governance_changed=true
        ;;
    esac
  done < <(git diff --name-only "$base_ref...HEAD")

  if [[ "$governance_changed" == true ]]; then
    git log --format=%B "$base_ref..HEAD" | grep -Fq -- '[governance-change]' || \
      fail 'governance files changed without [governance-change]'

    if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
      pr_body="${GOVERNANCE_PR_BODY:-}"
      [[ -n "$pr_body" ]] || fail 'governance PR body is empty'
      for required_pr_text in \
        '## 规范变更对照' \
        '变更前规则：' \
        '变更后规则：' \
        '保留或迁移到的规范文件：' \
        '影响范围：' \
        '迁移方式：' \
        '明确不做事项：' \
        '功能源码、可执行功能测试代码、产品配置或依赖是否变化：' \
        '文档导航及 README 稳定入口是否同步：' \
        '核心治理 PR 是否保持 Draft 等待维护者或用户逐项确认：' \
        '转为 Ready 或合入的明确批准来源：'; do
        grep -Fq -- "$required_pr_text" <<< "$pr_body" || \
          fail "governance PR body is missing: $required_pr_text"
      done

      grep -Eq -- '^功能源码、可执行功能测试代码、产品配置或依赖是否变化：否[[:space:]]*$' <<< "$pr_body" || \
        fail 'governance PR must explicitly confirm that product files do not change'
      grep -Eq -- '^文档导航及 README 稳定入口是否同步：是[[:space:]]*$' <<< "$pr_body" || \
        fail 'governance PR must explicitly confirm the documentation entry points are synchronized'
      grep -Eq -- '^核心治理 PR 是否保持 Draft 等待维护者或用户逐项确认：是[[:space:]]*$' <<< "$pr_body" || \
        fail 'governance PR must remain Draft for explicit maintainer or user review'

      if [[ "${GOVERNANCE_PR_IS_DRAFT:-}" != true ]]; then
        approval_source="$(sed -n 's/^转为 Ready 或合入的明确批准来源：[[:space:]]*//p' <<< "$pr_body" | tail -n 1)"
        [[ -n "$approval_source" ]] || \
          fail 'ready governance PR is missing an explicit approval source'
        [[ "$approval_source" != N/A ]] || \
          fail 'ready governance PR cannot use N/A as its approval source'
        [[ "$approval_source" != '确认渠道、日期与明确指令' ]] || \
          fail 'ready governance PR must replace the approval-source placeholder'
      fi
    fi

    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      case "$path" in
        AGENTS.md|BRANCH_MANAGEMENT.md|DOCUMENTATION.md|FEATURE_DEVELOPMENT.md|FILE_NAMING.md|LOGGING.md|RELEASING.md|README.md|design-qa.md|design-qa.en.md|Bugs/README.md|Testing/*.md|feature/*/PRODUCT_SPEC.md|feature/*/platform-*.md|feature/*/testing.md|.github/PULL_REQUEST_TEMPLATE.md|.github/workflows/repository-governance.yml|scripts/verify-repository-governance.sh)
          ;;
        *)
          scope_violation=true
          printf 'out-of-scope governance path: %s\n' "$path" >&2
          ;;
      esac
    done < <(git diff --name-only "$base_ref...HEAD")

    if [[ "$scope_violation" == true ]]; then
      fail 'governance changes must use a dedicated PR without product, release implementation, or unrelated files'
    fi
  fi
fi

printf 'repository governance check passed\n'
