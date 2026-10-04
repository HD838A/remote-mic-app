#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'repository governance check failed: %s\n' "$1" >&2
  exit 1
}

governance_changed=false
new_engineering_helper=false
base_ref="${1:-}"
if [[ -n "$base_ref" && "$base_ref" != 0000000000000000000000000000000000000000 ]]; then
  git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1 || fail "base commit is unavailable: $base_ref"

  new_engineering_helper=false
  while IFS= read -r -d '' path; do
    case "$path" in
      scripts/voice-acceptance.sh|Testing/build_rc003_preview.sh|Testing/启动Chromecast真机测试.command|Testing/启动RC003长语音测试.command|Testing/launch_rc003_voice_extension_test.command|scripts/run-apple-remote-no-packetlogger-probe.sh)
        fail "retired manual tooling must not be restored: $path"
        ;;
    esac
    lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    file_mode="$(git ls-files --stage -- "$path" | awk 'NR == 1 { print $1 }')"
    case "$lower_path" in
      testing/*.sh|testing/*.bash|testing/*.zsh|testing/*.command|testing/*.swift|testing/*.py|testing/*.js|testing/*.mjs|testing/*.cjs|testing/*.ts|testing/*.rb|testing/*.pl|testing/*.ps1|testing/*.bat|testing/*.cmd)
        fail "Testing must not gain executable helpers: $path"
        ;;
    esac
    if [[ "$lower_path" == testing/* && "$file_mode" == 100755 ]]; then
      fail "Testing must not gain executable helpers: $path"
    fi
    case "$lower_path" in
      scripts/*|script/*)
        new_engineering_helper=true
        ;;
    esac
  done < <(git diff --no-renames --diff-filter=A --name-only -z "$base_ref...HEAD")

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

export GOVERNANCE_CHANGED="$governance_changed"
export GOVERNANCE_NEW_HELPER="$new_engineering_helper"

# Stable declarations and typed PR fields allow prose edits without weakening scope gates.
python3 - <<'PY_GOVERNANCE'
import os
import re
from pathlib import Path


def fail(message):
    raise SystemExit(f"repository governance check failed: {message}")


def fields(text, language, required=False):
    blocks = re.findall(rf"^```{re.escape(language)}[ \t]*\n(.*?)^```[ \t]*$", text, re.M | re.S)
    if required and len(blocks) != 1:
        fail(f"expected one {language} block, found {len(blocks)}")
    result = {}
    for block in blocks:
        for line in block.splitlines():
            if not line.strip():
                continue
            match = re.fullmatch(r"([A-Za-z][A-Za-z0-9_.-]*)=(.+)", line)
            if not match:
                fail(f"invalid {language} field: {line}")
            key, value = match.groups()
            if key in result:
                fail(f"duplicate {language} field: {key}")
            result[key] = value.strip()
    return result


policies = {
    "BRANCH_MANAGEMENT.md": {
        "G-MAIN.start": "latest-origin-main", "G-MAIN.sync": "impact-based",
        "G-MAIN.release": "exact-approved-main", "G-WORK.pr": "single",
        "G-DUP.scan": "all-open-titles-labels", "G-DUP.inspect": "relevant-description-files-diff",
        "G-AUDIT.inventory": "required", "G-AUDIT.cleanup": "separate-authorization",
        "G-TODO.branch": "codex/todo_list", "G-TODO.delivery": "batch-or-draft",
        "G-TODO.product": "forbidden", "G-WORK.commit": "single",
        "G-ASSET.threshold": "5MB", "G-ASSET.authorization": "file-or-bounded-budget",
        "G-ASSET.host-limit": "required", "G-GOV.scope": "dedicated-allowlist",
        "G-GOV.commit-marker": "[governance-change]", "G-GOV.approval": "concrete-plan-or-result",
        "G-GOV.validation": "local-required", "G-GOV.required-check": "Repository governance",
        "G-CI.default": "wait-pass", "G-CI.exception": "explicit-current-pr",
        "G-CI.bypass": "pull_request", "G-CI.status": "truthful",
        "G-CI.other-gates": "retained", "G-MERGE.default": "merge",
    },
    "AGENTS.md": {
        "G-DOC.entry": "DOCUMENTATION.md", "G-DOC.authority": "chinese",
        "G-TOOL.temporary": "forbidden", "G-TOOL.testing-executable": "forbidden",
        "G-TOOL.permanent-helper": "declared-purpose", "G-SCOPE.query": "read-only",
        "G-SCOPE.unrelated": "separate", "G-WAIT.mode": "bounded",
        "G-CI.reference": "BRANCH_MANAGEMENT.md", "G-ONBOARD.validation": "risk-based",
        "G-ONBOARD.manifest": "production", "G-ONBOARD.real-acceptance": "retained",
        "G-BUG.investigation": "evidence-driven", "G-BUG.fix": "confirmed-cause",
        "G-BUG.real-acceptance": "retained",
    },
    "FEATURE_DEVELOPMENT.md": {
        "G-MAIN.reference": "BRANCH_MANAGEMENT.md", "G-CI.reference": "BRANCH_MANAGEMENT.md",
    },
    "RELEASING.md": {"G-NOTES.content": "user-visible", "G-NOTES.unpublished": "excluded"},
}
for filename, expected in policies.items():
    text = Path(filename).read_text()
    actual = fields(text, "governance-policy")
    if actual != expected:
        fail(f"{filename} stable policy declarations differ: "
             f"{sorted(key for key in actual.keys() | expected.keys() if actual.get(key) != expected.get(key))}")
    # Each declaration belongs to a real normative section, with explanatory prose.
    for section in re.split(r"(?m)^## ", text)[1:]:
        if "```governance-policy" not in section:
            continue
        prose = re.sub(r"(?ms)^```governance-policy.*?^```", "", section)
        if not re.search(r"(?m)^(?:- |[0-9]+\. ).+", prose):
            fail(f"{filename} policy section lacks normative prose")

navigation = Path("DOCUMENTATION.md").read_text()
readme = Path("README.md").read_text()
links = re.findall(r"\[[^\]]*\]\(([^)]+)\)", navigation)
required_docs = list(Path("feature").rglob("PRODUCT_SPEC.md"))
required_docs += list(Path("feature").rglob("platform-*.md"))
required_docs += list(Path("Testing").glob("*Contract.md"))
required_docs += [Path(name) for name in policies]
for path in required_docs:
    if path.as_posix() not in links:
        fail(f"documentation navigation is missing {path}")
if "DOCUMENTATION.md" not in re.findall(r"\[[^\]]*\]\(([^)]+)\)", Path("AGENTS.md").read_text()):
    fail("AGENTS must link to the stable documentation entry")
if len(re.findall(r"\[[^\]]*\]\(DOCUMENTATION\.md\)", readme)) != 1:
    fail("README must contain exactly one stable documentation navigation link")
if re.search(r"(?m)^## 规范文件索引\s*$", readme) or "```governance-policy" in readme:
    fail("README must not embed the specification index")

# Derive filenames from the production list; counts alone cannot detect missing pages.
renderer = Path("Sources/RemoteMic/OnboardingScreenshotRenderer.swift").read_text()
page_function = re.search(r"private static func pages\(.*?return steps\.enumerated", renderer, re.S)
filename_function = re.search(r"private static func filenameComponent\(.*?\n    }", renderer, re.S)
if not page_function or not filename_function:
    fail("production screenshot list cannot be read; update the manifest parser with the renderer")
steps = re.findall(r"(?m)^\s*\.([A-Za-z]+),\s*$", page_function.group())
components = dict(re.findall(r'case \.([A-Za-z]+): return "([a-z-]+)"', filename_function.group()))
if not steps or len(steps) != len(set(steps)) or any(step not in components for step in steps):
    fail("production screenshot list is empty, duplicated, or lacks filename mappings")
expected_pages = [(step, f"{index:02d}-{components[step]}.png") for index, step in enumerate(steps, 1)]
manual = Path("Testing/FirstRunOnboarding.md").read_text()
manifest = re.search(r"(?m)^## 生产页面与场景清单\n(.*?)(?=^## |\Z)", manual, re.S)
if not manifest:
    fail("Onboarding test manual lacks the production scenario manifest")
actual_pages = re.findall(r"(?m)^\| ([A-Za-z]+) \| `([0-9]+-[a-z-]+\.png)` \|$", manifest.group(1))
if actual_pages != expected_pages:
    fail("Onboarding screenshot manifest differs from production filenames or order")

schema = {
    "kind", "before", "after", "files", "scope", "migration", "excluded", "product_files",
    "documentation_synced", "approval_basis", "approval", "approval_scope", "plan_changed",
    "validation", "validation_result", "ci_mode", "ci_authorization", "ci_scope", "ci_unverified",
    "helper_scope", "helper_purpose",
}
template = fields(Path(".github/PULL_REQUEST_TEMPLATE.md").read_text(), "governance", required=True)
if template.keys() != schema:
    fail("PR template stable fields do not match the schema")


def concrete(value):
    value = value.strip()
    return bool(value) and not (
        re.match(r"(?i)^(?:n/?a|none|null|tbd|todo|pending|placeholder)(?:\b|[ /：:])", value)
        or re.match(r"^(?:待填写|待确认|未填写|不适用|确认渠道|用户原话|在这里|填写)", value)
        or value in {"...", "…", "-"}
    )


if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
    body = os.environ.get("GOVERNANCE_PR_BODY", "")
    governance = os.environ["GOVERNANCE_CHANGED"] == "true"
    helper = os.environ["GOVERNANCE_NEW_HELPER"] == "true"
    metadata = fields(body, "governance", required=governance or helper)
    if metadata:
        if metadata.keys() != schema:
            fail("PR stable fields do not match the schema")
        for key, allowed in {
            "kind": {"governance", "product", "maintenance"},
            "product_files": {"true", "false"}, "documentation_synced": {"true", "false"},
            "plan_changed": {"true", "false"},
            "approval_basis": {"pending", "approved-plan", "reviewed-result"},
            "validation_result": {"pass", "pending", "fail"},
            "ci_mode": {"default", "no-wait", "skip", "allow-failure"},
            "helper_scope": {"N/A", "permanent"},
        }.items():
            if metadata[key] not in allowed:
                fail(f"invalid PR field {key}: {metadata[key]}")
        if metadata["ci_mode"] != "default":
            for key in ("ci_authorization", "ci_scope", "ci_unverified"):
                if not concrete(metadata[key]):
                    fail(f"CI exception lacks concrete {key}")
        if governance:
            if metadata["kind"] != "governance" or metadata["product_files"] != "false":
                fail("governance PR must declare its kind and absence of product files")
            if metadata["documentation_synced"] != "true":
                fail("governance PR must synchronize documentation entry points")
            for key in ("before", "after", "files", "scope", "migration", "excluded", "validation"):
                if not concrete(metadata[key]):
                    fail(f"governance PR lacks concrete {key}")
            if os.environ.get("GOVERNANCE_PR_IS_DRAFT") != "true":
                if metadata["validation_result"] != "pass":
                    fail("Ready governance PR requires successful local checks")
                basis = metadata["approval_basis"]
                if basis == "pending" or (basis == "approved-plan" and metadata["plan_changed"] != "false"):
                    fail("Ready governance PR needs approval covering the current plan or reviewed changes")
                for key in ("approval", "approval_scope"):
                    if not concrete(metadata[key]):
                        fail(f"Ready governance PR lacks concrete {key}")
        if helper and (metadata["helper_scope"] != "permanent" or not concrete(metadata["helper_purpose"])):
            fail("new engineering helper requires permanent scope and a concrete purpose")
    # During migration, existing product PRs may retain the previous CI checkbox.
    # Keep its authorization checks; it cannot bypass structured governance/helper checks.
    if re.search(r"(?mi)^\s*-?\s*\[x\] 用户明确要求本 PR 不等待或跳过 CI", body):
        for label in ("CI 例外授权", "CI 例外范围", "CI 未验证项"):
            values = re.findall(rf"(?m)^{label}：[ \t]*(.*)$", body)
            if len(values) != 1 or not concrete(values[0]):
                fail(f"legacy CI exception lacks concrete {label}")
PY_GOVERNANCE

printf 'repository governance check passed\n'
