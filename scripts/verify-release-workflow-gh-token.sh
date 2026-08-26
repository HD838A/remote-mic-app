#!/bin/zsh
set -euo pipefail
umask 077
setopt null_glob

ROOT="${REPOSITORY_ROOT:-${0:A:h:h}}"
WORKFLOW_DIR="$ROOT/.github/workflows"

for workflow in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [[ -f "$workflow" ]] || continue
  /usr/bin/awk -v workflow="$workflow" '
    function check_step() {
      if (index(step, "gh ") > 0 || index(step, "gh\t") > 0 || index(step, "gh\n") > 0) {
        if (step !~ /GH_TOKEN:[[:space:]]*\$\{\{[^}]+\}\}/) {
          print workflow ":" start_line ": a step invokes gh without an explicit step-scoped GH_TOKEN" > "/dev/stderr"
          failed = 1
        }
      }
    }
    /^      - name:/ {
      check_step()
      step = $0 "\n"
      start_line = NR
      next
    }
    { step = step $0 "\n" }
    END {
      check_step()
      exit failed
    }
  ' "$workflow"
done

print "RELEASE WORKFLOW GH_TOKEN PASS"
