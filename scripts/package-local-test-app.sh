#!/bin/zsh
# Build and install a local SayAll test app with the project's native packager.
# Inputs: SAYALL_PRIVATE_SOURCE_ROOT, SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH,
# CODE_SIGN_IDENTITY, and the diagnostic settings required by build-app.sh.
# Set SAYALL_LOCAL_DEFER_LAUNCH=1 to install without launching.
set -euo pipefail

ROOT="${0:A:h:h}"
TARGET="${SAYALL_LOCAL_APP_TARGET:-$HOME/Applications/SayAll.app}"
FALLBACK="${SAYALL_LOCAL_APP_FALLBACK:-$HOME/Downloads/SayAll-test}/SayAll.app"
STATE="$HOME/.sayall-local-build"

: "${SAYALL_PRIVATE_SOURCE_ROOT:?Set the private platform source root}"
test -d "$SAYALL_PRIVATE_SOURCE_ROOT/packages"
: "${SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH:?Set the prepared private artifact package}"
: "${CODE_SIGN_IDENTITY:?Set the local Developer ID signing identity}"

platform_version="$(jq -er '.dependencies.sayAllPrivatePlatform.version' "$ROOT/config/release-dependencies.json")"
if [[ -n "${SAYALL_LOCAL_PRIVATE_SOURCE_COMMIT:-}" ]]; then
  source_commit_expected="$SAYALL_LOCAL_PRIVATE_SOURCE_COMMIT"
  python3 "$ROOT/scripts/prepare-private-platform.py" check-checkout \
    --checkout "$SAYALL_PRIVATE_SOURCE_ROOT" --channel local --local-commit "$source_commit_expected"
else
  source_commit_expected="$(git -C "$SAYALL_PRIVATE_SOURCE_ROOT" rev-parse "refs/tags/$platform_version^{commit}")"
fi
artifact_commit="$(jq -er '.sourceCommit' "$SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH/private-artifact-package.json")"
if [[ "$source_commit_expected" != "$artifact_commit" ]]; then
  print -u2 "Prepared private artifacts do not match the selected private source."
  exit 1
fi

zmodload zsh/system
touch "$STATE.lock"
if ! zsystem flock -t 0 "$STATE.lock"; then
  print -u2 "Another SayAll local build is in progress."
  exit 1
fi

max_build=0
for app in /Applications/SayAll.app "$HOME/Applications/SayAll.app" "$TARGET" "$FALLBACK"; do
  value="$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$value" == <-> ]] && (( value > max_build )); then
    max_build="$value"
  fi
done
if [[ -f "$STATE" ]]; then
  value="$(<"$STATE")"
  if [[ "$value" == <-> ]] && (( value > max_build )); then
    max_build="$value"
  fi
fi
next_build=$((max_build + 1))
source_commit="$(git -C "$ROOT" rev-parse HEAD)"
dirty=false
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  dirty=true
fi

if [[ "$(uname -m)" == x86_64 ]]; then
  RELEASE_VARIANT=intel
else
  RELEASE_VARIANT=apple-silicon
fi
source "$ROOT/scripts/release-variant.sh"
export CONFIGURATION=release
export SAYALL_BUILD_CHANNEL=local
if [[ -n "${SAYALL_LOCAL_PRIVATE_SOURCE_COMMIT:-}" ]]; then
  unset SAYALL_PRIVATE_PLATFORM_VERSION
else
  export SAYALL_PRIVATE_PLATFORM_VERSION="$platform_version"
fi
export SAYALL_PRIVATE_PLATFORM_MODE=required
export REQUIRE_SAYALL_PRIVATE_ARTIFACT_PACKAGE=1
export REQUIRE_SAYALL_COMBINATION_ACTIONS=1
export REQUIRE_SAYALL_BUTTON_PROFILES=1
export REQUIRE_SAYALL_MAC_REMOTE_PACKAGE=1
export REQUIRE_SAYALL_CHROMECAST=1
export REQUIRE_SIRI_REMOTE_SIGNING=1
"$ROOT/scripts/build-app.sh"

app="$RELEASE_OUTPUT_DIR/SayAll.app"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$next_build" "$plist"
plutil -insert SayAllSourceDirty -bool "$dirty" "$plist"
codesign --force --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY" \
  --entitlements "$ROOT/packaging/app.entitlements" "$app"
codesign --verify --deep --strict "$app"
"$ROOT/scripts/verify-app.sh" "$app"

install_app() {
  local destination="$1" staged backup=""
  mkdir -p "${destination:h}" || return 1
  staged="$(mktemp -d "${destination:h}/.sayall-stage.XXXXXX")" || return 1
  {
    ditto "$app" "$staged/SayAll.app" || return 1
    codesign --verify --deep --strict "$staged/SayAll.app" || return 1
    if [[ -e "$destination" ]]; then
      backup="$HOME/.Trash/SayAll.app.local-$(date -u +%Y%m%dT%H%M%S)-$$"
      test ! -e "$backup" && mv "$destination" "$backup" || return 1
    fi
    if ! mv "$staged/SayAll.app" "$destination"; then
      if [[ -n "$backup" ]] && ! mv "$backup" "$destination"; then
        print -u2 -- "Could not restore the previous SayAll app. Recover it from: $backup"
        return 2
      fi
      return 1
    fi
  } always {
    mv "$staged" "$HOME/.Trash/${staged:t}-$$" ||
      print -u2 -- "Could not move the staging directory to Trash: $staged"
  }
}

for old_app in /Applications/SayAll.app "$TARGET" "$FALLBACK"; do
  for pid in $(pgrep -fx -- "$old_app/Contents/MacOS/RemoteMic" || true); do
    kill -TERM "$pid"
    for attempt in {1..25}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      print -u2 "The previous SayAll instance did not exit."
      exit 1
    fi
  done
done

final="$TARGET"
install_status=0
install_app "$final" || install_status=$?
case "$install_status" in
  0) ;;
  1)
    final="$FALLBACK"
    install_app "$final"
    ;;
  *) exit "$install_status" ;;
esac
codesign --verify --deep --strict "$final"
print "$next_build" > "$STATE"
print "Installed $final, build $next_build, source $source_commit, dirty=$dirty"
if [[ "${SAYALL_LOCAL_DEFER_LAUNCH:-0}" != 1 ]]; then
  open -a "$final"
fi
