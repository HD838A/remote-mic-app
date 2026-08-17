#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_ROOT="$(/usr/bin/mktemp -d /private/tmp/sayall-legacy-trash-test.XXXXXX)"
TARGET_VOLUME="$TEST_ROOT/target"
TRASH_ROOT="$TARGET_VOLUME/.Trashes/$(/usr/bin/id -u)"
MESSAGES="$TEST_ROOT/messages.txt"

cleanup() {
  case "$TEST_ROOT" in
    /private/tmp/sayall-legacy-trash-test.*) ;;
    *) print -u2 "refusing to clean unexpected test path: $TEST_ROOT"; return ;;
  esac
  local recovery_root="${HOME}/.Trash"
  if [[ -d "$recovery_root" ]]; then
    local recovery_container
    recovery_container="$(/usr/bin/mktemp -d "$recovery_root/sayall-legacy-trash-test.XXXXXX")"
    /bin/mv -n -- "$TEST_ROOT" "$recovery_container/"
  else
    print -u2 "test artifacts remain recoverable at $TEST_ROOT"
  fi
}
trap cleanup EXIT

installer_message() {
  print -r -- "$2" | /usr/bin/tee -a "$MESSAGES"
}

source "$ROOT/packaging/doubao-driver/install/trash-legacy-app.zsh"

make_app() {
  local path="$1"
  local identifier="$2"
  /bin/mkdir -p "$path/Contents"
  /usr/bin/plutil -create xml1 "$path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" \
    "$path/Contents/Info.plist"
  print -r -- "recoverable payload" > "$path/Contents/recovery-marker.txt"
}

CANONICAL_APP="$TARGET_VOLUME/Applications/SayAll.app"
make_app "$CANONICAL_APP" "com.hd838a.RemoteMic"

FIRST_APP="$TARGET_VOLUME/Applications/Remote Mic.app"
make_app "$FIRST_APP" "com.hd838a.RemoteMic"
move_legacy_app_to_trash_if_owned \
  "$FIRST_APP" "$FIRST_APP/Contents/Info.plist" "Remote Mic.app" \
  "$TRASH_ROOT" "$(/usr/bin/id -u)" "fixed-token"
FIRST_TRASHED="$TRASH_ROOT/Remote Mic (migrated fixed-token).app"
test -f "$FIRST_TRASHED/Contents/recovery-marker.txt"
RESTORED_APP="$TARGET_VOLUME/Restored/Remote Mic.app"
/bin/mkdir -p "${RESTORED_APP:h}"
/bin/mv -n -- "$FIRST_TRASHED" "$RESTORED_APP"
test -f "$RESTORED_APP/Contents/recovery-marker.txt"

SECOND_APP="$TARGET_VOLUME/Applications/Remote Mic.app"
THIRD_APP="$TARGET_VOLUME/Other/Applications/Remote Mic.app"
make_app "$SECOND_APP" "com.hd838a.RemoteMic"
make_app "$THIRD_APP" "com.hd838a.RemoteMic"
move_legacy_app_to_trash_if_owned \
  "$SECOND_APP" "$SECOND_APP/Contents/Info.plist" "Remote Mic.app" \
  "$TRASH_ROOT" "$(/usr/bin/id -u)" "collision-token"
move_legacy_app_to_trash_if_owned \
  "$THIRD_APP" "$THIRD_APP/Contents/Info.plist" "Remote Mic.app" \
  "$TRASH_ROOT" "$(/usr/bin/id -u)" "collision-token"
test -d "$TRASH_ROOT/Remote Mic (migrated collision-token).app"
test -d "$TRASH_ROOT/Remote Mic (migrated collision-token-1).app"

FOREIGN_APP="$TARGET_VOLUME/Applications/无线麦.app"
make_app "$FOREIGN_APP" "com.example.NotSayAll"
move_legacy_app_to_trash_if_owned \
  "$FOREIGN_APP" "$FOREIGN_APP/Contents/Info.plist" "无线麦.app" \
  "$TRASH_ROOT" "$(/usr/bin/id -u)" "foreign-token"
test -d "$FOREIGN_APP"

UNAVAILABLE_APP="$TARGET_VOLUME/Unavailable/Applications/无线麦.app"
make_app "$UNAVAILABLE_APP" "com.hd838a.RemoteMic"
UNAVAILABLE_TRASH="$TARGET_VOLUME/unavailable-trash"
print -r -- "not a directory" > "$UNAVAILABLE_TRASH"
move_legacy_app_to_trash_if_owned \
  "$UNAVAILABLE_APP" "$UNAVAILABLE_APP/Contents/Info.plist" "无线麦.app" \
  "$UNAVAILABLE_TRASH" "$(/usr/bin/id -u)" "unavailable-token"
test -d "$UNAVAILABLE_APP"
/usr/bin/grep -Fq "Trash was unavailable" "$MESSAGES"

MV_FAILURE_APP="$TARGET_VOLUME/MoveFailure/Applications/Remote Mic.app"
make_app "$MV_FAILURE_APP" "com.hd838a.RemoteMic"
MV_FAILURE_TRASH="$TARGET_VOLUME/read-only-trash"
/bin/mkdir -p "$MV_FAILURE_TRASH"
/bin/chmod 500 "$MV_FAILURE_TRASH"
move_legacy_app_to_trash_if_owned \
  "$MV_FAILURE_APP" "$MV_FAILURE_APP/Contents/Info.plist" "Remote Mic.app" \
  "$MV_FAILURE_TRASH" "$(/usr/bin/id -u)" "move-failure-token"
test -d "$MV_FAILURE_APP"
/usr/bin/grep -Fq "could not be moved to Trash and was left in place" "$MESSAGES"
/bin/chmod 700 "$MV_FAILURE_TRASH"

test -f "$CANONICAL_APP/Contents/recovery-marker.txt"

print "LEGACY APP TRASH MIGRATION TEST PASS"
