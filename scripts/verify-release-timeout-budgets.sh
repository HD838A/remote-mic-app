#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_SCRIPT="${1:-$ROOT/scripts/build-app.sh}"
NOTARIZE_SCRIPT="${2:-$ROOT/scripts/notarize-release.sh}"
VARIANT_SCRIPT="${3:-$ROOT/scripts/package-macos-release-variants.sh}"
WORKFLOW="${4:-$ROOT/.github/workflows/mac-release-package.yml}"

if [[ "$#" -gt 4 ]]; then
  print -u2 "usage: $0 [build-app] [notarize-release] [package-variants] [workflow]"
  exit 2
fi
for required_file in \
  "$BUILD_SCRIPT" "$NOTARIZE_SCRIPT" "$VARIANT_SCRIPT" "$WORKFLOW"; do
  [[ -r "$required_file" ]] || {
    print -u2 "release timeout input is unreadable: $required_file"
    exit 1
  }
done

extract_shell_default() {
  local file_path="$1"
  local variable_name="$2"
  /usr/bin/awk -v variable_name="$variable_name" '
    index($0, variable_name "=\"${" variable_name ":-") == 1 {
      value = $0
      sub(/^.*:-/, "", value)
      sub(/}\"$/, "", value)
      print value
      exit
    }
  ' "$file_path"
}

swift_build_timeout="$(extract_shell_default \
  "$BUILD_SCRIPT" RELEASE_SWIFT_BUILD_TIMEOUT_SECONDS)"
app_build_timeout="$(extract_shell_default \
  "$NOTARIZE_SCRIPT" RELEASE_APP_BUILD_TIMEOUT_SECONDS)"
variant_timeout="$(extract_shell_default \
  "$VARIANT_SCRIPT" RELEASE_VARIANT_TIMEOUT_SECONDS)"
signed_release_timeout="$(/usr/bin/sed -nE \
  's/^[[:space:]]*SIGNED_RELEASE_TIMEOUT_SECONDS:[[:space:]]*([0-9]+)$/\1/p' \
  "$WORKFLOW")"
step_timeout_minutes="$(/usr/bin/awk '
  index($0, "- name: Sign, notarize, staple, and verify both variants") { active = 1; next }
  active && /^[[:space:]]*- name:/ { exit }
  active && /timeout-minutes:/ {
    sub(/^.*timeout-minutes:[[:space:]]*/, "")
    print
    exit
  }
' "$WORKFLOW")"

for timeout_value in \
  "$swift_build_timeout" "$app_build_timeout" "$variant_timeout" \
  "$signed_release_timeout" "$step_timeout_minutes"; do
  if ! print -r -- "$timeout_value" | /usr/bin/grep -Eq '^[1-9][0-9]*$'; then
    print -u2 "release timeout budget is missing or invalid"
    exit 1
  fi
done

step_timeout_seconds=$(( step_timeout_minutes * 60 ))

if (( swift_build_timeout <= 180 )); then
  print -u2 "Swift Release build timeout must reject the obsolete 180-second budget"
  exit 1
fi
if (( app_build_timeout < swift_build_timeout + 30 )); then
  print -u2 "app-build must leave at least 30 seconds beyond app-swift-build"
  exit 1
fi
if (( app_build_timeout >= variant_timeout )); then
  print -u2 "app-build must remain inside signed-variant"
  exit 1
fi
if (( variant_timeout >= signed_release_timeout )); then
  print -u2 "signed-variant must remain inside signed-release"
  exit 1
fi
if (( signed_release_timeout != 590 )); then
  print -u2 "signed-release must retain the 590-second hard supervisor"
  exit 1
fi
if (( step_timeout_seconds != 600 )); then
  print -u2 "the protected signing step must retain the 600-second hard limit"
  exit 1
fi
if (( signed_release_timeout >= step_timeout_seconds )); then
  print -u2 "signed-release must finish before the workflow step hard limit"
  exit 1
fi

print "RELEASE TIMEOUT BUDGETS PASS"
print "app-swift-build=${swift_build_timeout}s app-build=${app_build_timeout}s signed-variant=${variant_timeout}s signed-release=${signed_release_timeout}s step=${step_timeout_seconds}s"
