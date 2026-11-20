#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SCRIPT="$ROOT/packaging/doubao-driver/uninstall/postinstall"
DRIVER_NAMING="$ROOT/packaging/doubao-driver/install/driver-naming.zsh"
WORK="$ROOT/.build/uninstaller-cleanup-tests/$(/usr/bin/uuidgen)"
/bin/mkdir -p "$WORK"

fail() {
  print -u2 "UNINSTALLER CLEANUP TEST FAILED: $1"
  exit 1
}

extract_function() {
  local name="$1"
  /usr/bin/sed -n "/^${name}() {/,/^}/p" "$SCRIPT"
}

# Static boundaries. The uninstaller must clear installation metadata and the
# current user's fixed Dock entry, but must not reference app preferences or
# logs as install targets.
/bin/zsh -n "$SCRIPT"
/usr/bin/grep -Fq 'com.hd838a.RemoteMic.siri-remote' "$SCRIPT" || \
  fail 'missing Siri Remote package identifier'
/usr/bin/grep -Fq -- '--forget' "$SCRIPT" || fail 'missing pkgutil forget'
/usr/bin/grep -Fq 'persistent-apps' "$SCRIPT" || fail 'missing Dock persistent-apps handling'
/usr/bin/grep -Fq '/usr/bin/killall Dock' "$SCRIPT" || fail 'missing Dock restart'
/usr/bin/grep -Fq 'MOVED_APP_PATHS' "$SCRIPT" || fail 'missing moved-app Dock matching'
/usr/bin/grep -Fq ')-$$"' "$SCRIPT" || fail 'uninstall token lost its process id'
if /usr/bin/grep -Eq 'Library/Preferences|Library/Logs' "$SCRIPT"; then
  fail 'uninstaller must not target app preferences or logs'
fi
if /usr/bin/grep -Eq '(/bin/)?rm([[:space:]]|$)|unlink|find[[:space:]].*-delete' "$SCRIPT"; then
  fail 'uninstaller must not permanently delete files'
fi

{
  extract_function run_as_console_user
  extract_function decode_dock_url
  extract_function remove_dock_indices
  extract_function cleanup_dock_tiles
} > "$WORK/dock-functions.zsh"
{
  extract_function siri_receipt_exists | \
    /usr/bin/sed 's#/usr/sbin/pkgutil#fixture_pkgutil#g'
  extract_function cleanup_siri_receipt | \
    /usr/bin/sed 's#/usr/sbin/pkgutil#fixture_pkgutil#g'
} > "$WORK/receipt-functions.zsh"

cat > "$WORK/dock-harness.zsh" <<'ZSH'
#!/bin/zsh
set -euo pipefail
FUNCTIONS="$1"
FIXTURE_DOCK="$2"
SCENARIO="$3"
TARGET_VOLUME="$4"
source "$FUNCTIONS"

fixture_defaults() {
  case "$1" in
    export)
      /bin/cat "$FIXTURE_DOCK"
      ;;
    import)
      if [[ "$SCENARIO" == write_failure ]]; then
        /bin/cat >/dev/null
        return 1
      fi
      /bin/cat > "$FIXTURE_DOCK"
      ;;
    *)
      return 1
      ;;
  esac
}

run_as_console_user() {
  if [[ "$1" == /usr/bin/defaults ]]; then
    shift
    fixture_defaults "$@"
  else
    return 0
  fi
}

CONSOLE_USER="fixture"
CONSOLE_UID="501"
CONSOLE_HOME="/fixture"
MOVED_APP_PATHS=()
DOCK_TILE_REMOVED=0
DOCK_TILE_FAILED=0
case "$SCENARIO" in
  match)
    MOVED_APP_PATHS=(
      "/Applications/SayAll.app"
      "/Users/fixture/.Trash/SayAll (uninstalled fixture).app"
      "/Applications/Remote Mic.app"
      "/Applications/无线麦.app"
    )
    ;;
  no_match)
    MOVED_APP_PATHS=("/Applications/Missing.app")
    ;;
  console_unavailable)
    CONSOLE_USER=""
    MOVED_APP_PATHS=("/Applications/SayAll.app")
    ;;
  *)
    MOVED_APP_PATHS=("/Applications/SayAll.app")
    ;;
esac
if cleanup_dock_tiles; then
  rc=0
else
  rc=$?
fi
print "rc=$rc removed=$DOCK_TILE_REMOVED failed=$DOCK_TILE_FAILED"
exit "$rc"
ZSH

cat > "$WORK/receipt-harness.zsh" <<'ZSH'
#!/bin/zsh
set -euo pipefail
FUNCTIONS="$1"
SCENARIO="$2"
FORGET_LOG="$3"
source "$FUNCTIONS"

fixture_pkgutil() {
  if [[ "$3" == --pkg-info ]]; then
    [[ "$SCENARIO" != absent ]]
    return
  fi
  if [[ "$3" == --forget ]]; then
    print -r -- "$4" >> "$FORGET_LOG"
    [[ "$SCENARIO" != forget_failure ]]
    return
  fi
  return 1
}

TARGET_VOLUME="/"
SIRI_REMOTE_PACKAGE_ID="com.hd838a.RemoteMic.siri-remote"
HCI_SERVICE_UNOWNED=0
SIRI_RECEIPT_PRESENT=0
SIRI_RECEIPT_FORGOTTEN=0
SIRI_RECEIPT_FAILED=0
[[ "$SCENARIO" == unowned ]] && HCI_SERVICE_UNOWNED=1
if cleanup_siri_receipt; then
  rc=0
else
  rc=$?
fi
print "rc=$rc present=$SIRI_RECEIPT_PRESENT forgotten=$SIRI_RECEIPT_FORGOTTEN failed=$SIRI_RECEIPT_FAILED"
exit "$rc"
ZSH
/bin/chmod 755 "$WORK/dock-harness.zsh" "$WORK/receipt-harness.zsh"

write_dock_fixture() {
  python3 - "$1" <<'PY'
import plistlib
import sys

entries = [
    {"tile-data": {"file-label": "Keep", "file-data": {"_CFURLString": "file:///Applications/Keep.app/"}}},
    {"tile-data": {"file-label": "SayAll", "file-data": {"_CFURLString": "file:///Applications/SayAll.app/"}}},
    {"tile-data": {"file-label": "Trashed", "file-data": {"_CFURLString": "file:///Users/fixture/.Trash/SayAll%20(uninstalled%20fixture).app/"}}},
    {"tile-data": {"file-label": "Remote Mic", "file-data": {"_CFURLString": "file:///Applications/Remote%20Mic.app/"}}},
    {"tile-data": {"file-label": "Chinese", "file-data": {"_CFURLString": "file:///Applications/%E6%97%A0%E7%BA%BF%E9%BA%A6.app/"}}},
    {"tile-data": {"file-label": "Other", "file-data": {"_CFURLString": "file:///Applications/Other.app/"}}},
]
with open(sys.argv[1], "wb") as stream:
    plistlib.dump({"persistent-apps": entries, "orientation": "bottom", "other-key": "keep"}, stream)
PY
}

assert_dock_result() {
  local plist="$1"
  local expected="$2"
  python3 - "$plist" "$expected" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    data = plistlib.load(stream)
labels = [entry["tile-data"]["file-label"] for entry in data["persistent-apps"]]
expected = sys.argv[2].split(",")
assert labels == expected, (labels, expected)
assert data.get("orientation") == "bottom", data
assert data.get("other-key") == "keep", data
PY
}

DOCK_FIXTURE="$WORK/dock.plist"
write_dock_fixture "$DOCK_FIXTURE"
dock_output="$("$WORK/dock-harness.zsh" "$WORK/dock-functions.zsh" "$DOCK_FIXTURE" match /)"
print -r -- "$dock_output"
print -r -- "$dock_output" | /usr/bin/grep -Fq 'DOCK_TILE phase=cleanup result=removed count=4' || \
  fail 'dock match did not remove three entries'
print -r -- "$dock_output" | /usr/bin/grep -Fq 'rc=0 removed=4 failed=0' || \
  fail 'dock match returned an unexpected status'
assert_dock_result "$DOCK_FIXTURE" "Keep,Other"

write_dock_fixture "$DOCK_FIXTURE"
dock_output="$("$WORK/dock-harness.zsh" "$WORK/dock-functions.zsh" "$DOCK_FIXTURE" no_match /)"
print -r -- "$dock_output" | /usr/bin/grep -Fq 'DOCK_TILE phase=cleanup result=no_match' || \
  fail 'dock no-match branch missing'
assert_dock_result "$DOCK_FIXTURE" "Keep,SayAll,Trashed,Remote Mic,Chinese,Other"

write_dock_fixture "$DOCK_FIXTURE"
dock_output="$("$WORK/dock-harness.zsh" "$WORK/dock-functions.zsh" "$DOCK_FIXTURE" match /Volumes/Fixture)"
print -r -- "$dock_output" | /usr/bin/grep -Fq 'result=skipped reason=non_boot_volume' || \
  fail 'non-boot volume was not skipped'

write_dock_fixture "$DOCK_FIXTURE"
dock_output="$("$WORK/dock-harness.zsh" "$WORK/dock-functions.zsh" "$DOCK_FIXTURE" console_unavailable /)"
print -r -- "$dock_output" | /usr/bin/grep -Fq 'result=skipped reason=console_user_unavailable' || \
  fail 'missing console user was not skipped'

write_dock_fixture "$DOCK_FIXTURE"
if dock_output="$("$WORK/dock-harness.zsh" "$WORK/dock-functions.zsh" "$DOCK_FIXTURE" write_failure / 2>&1)"; then
  fail 'dock write failure returned success'
fi
print -r -- "$dock_output" | /usr/bin/grep -Fq 'result=failed reason=preferences_write_failed' || \
  fail 'dock write failure reason missing'

FORGET_LOG="$WORK/forget.log"
: > "$FORGET_LOG"
receipt_output="$("$WORK/receipt-harness.zsh" "$WORK/receipt-functions.zsh" present "$FORGET_LOG")"
print -r -- "$receipt_output" | /usr/bin/grep -Fq 'result=forgotten' || fail 'receipt forget missing'
print -r -- "$receipt_output" | /usr/bin/grep -Fq 'rc=0 present=1 forgotten=1 failed=0' || \
  fail 'receipt forget flags are wrong'
/usr/bin/grep -Fq 'com.hd838a.RemoteMic.siri-remote' "$FORGET_LOG" || fail 'receipt id not forgotten'

receipt_output="$("$WORK/receipt-harness.zsh" "$WORK/receipt-functions.zsh" absent "$FORGET_LOG")"
print -r -- "$receipt_output" | /usr/bin/grep -Fq 'result=skipped reason=absent' || \
  fail 'absent receipt was not skipped'

receipt_output="$("$WORK/receipt-harness.zsh" "$WORK/receipt-functions.zsh" unowned "$FORGET_LOG")"
print -r -- "$receipt_output" | /usr/bin/grep -Fq 'result=skipped reason=unowned_component_present' || \
  fail 'unowned component did not preserve the receipt'

if receipt_output="$("$WORK/receipt-harness.zsh" "$WORK/receipt-functions.zsh" forget_failure "$FORGET_LOG" 2>&1)"; then
  fail 'receipt forget failure returned success'
fi
print -r -- "$receipt_output" | /usr/bin/grep -Fq 'result=failed reason=forget_failed' || \
  fail 'receipt forget failure reason missing'

# Execute the shipped early-exit branch with a stale receipt and no install
# items. Only pkgutil is replaced; the real script owns the rest of the flow.
EARLY_ROOT="$WORK/early"
/bin/mkdir -p "$EARLY_ROOT/scripts" "$EARLY_ROOT/volume"
/usr/bin/sed 's#/usr/sbin/pkgutil#fixture_pkgutil#g' "$SCRIPT" \
  > "$EARLY_ROOT/scripts/postinstall"
/usr/bin/ditto "$DRIVER_NAMING" "$EARLY_ROOT/scripts/driver-naming.zsh"
cat > "$EARLY_ROOT/scripts/run.zsh" <<'ZSH'
#!/bin/zsh
set -euo pipefail
fixture_pkgutil() {
  if [[ "$3" == --pkg-info ]]; then
    [[ "${UNINSTALLER_TEST_SCENARIO:-present}" != absent ]]
    return
  fi
  if [[ "$3" == --forget ]]; then
    print -r -- "$4" >> "$UNINSTALLER_TEST_FORGET_LOG"
    [[ "${UNINSTALLER_TEST_SCENARIO:-present}" != forget_failure ]]
    return
  fi
  return 1
}
source "${0:A:h}/postinstall"
ZSH
/bin/chmod 755 "$EARLY_ROOT/scripts/run.zsh"
: > "$FORGET_LOG"
early_output="$(UNINSTALLER_TEST_FORGET_LOG="$FORGET_LOG" \
  UNINSTALLER_TEST_SCENARIO=present \
  "$EARLY_ROOT/scripts/run.zsh" fixture fixture "$EARLY_ROOT/volume")"
print -r -- "$early_output" | /usr/bin/grep -Fq 'SIRI_RECEIPT phase=cleanup result=forgotten' || \
  fail 'early exit did not forget the stale receipt'
print -r -- "$early_output" | /usr/bin/grep -Fq 'No installation items were found' || \
  fail 'early exit did not report the stale receipt cleanup'
/usr/bin/grep -Fq 'com.hd838a.RemoteMic.siri-remote' "$FORGET_LOG" || \
  fail 'early exit did not emit forget'

if UNINSTALLER_TEST_FORGET_LOG="$FORGET_LOG" \
    UNINSTALLER_TEST_SCENARIO=forget_failure \
    "$EARLY_ROOT/scripts/run.zsh" fixture fixture "$EARLY_ROOT/volume" \
    > "$WORK/early-failure.log" 2>&1; then
  fail 'early exit forget failure returned success'
fi
/usr/bin/grep -Fq 'SIRI_RECEIPT phase=cleanup result=failed reason=forget_failed' \
  "$WORK/early-failure.log" || fail 'early exit forget failure reason missing'

print "UNINSTALLER CLEANUP TEST PASS"
