#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_BINARY="$ROOT/.build/debug/AppleRemoteAudioCapture"
PREF_DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debug"
PREF_PLIST="${PREF_DOMAIN}.plist"
PROBE_ROOT="$ROOT/.build/apple-remote-no-packetlogger-probe"
PROBE_RUN="$PROBE_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_PLIST="$PROBE_RUN/original-com.apple.MobileBluetooth.debug.plist"
ABSENT_MARKER="$PROBE_RUN/original-plist-absent"
PROBE_LOG="$PROBE_RUN/probe.log"
RESTORE_NEEDED=0

if [[ -d /Applications/PacketLogger.app ]]; then
  print -u2 "refusing probe: /Applications/PacketLogger.app is installed"
  exit 2
fi
if [[ ! -x "$PROBE_BINARY" ]]; then
  print -u2 "probe binary missing: run swift build first"
  exit 2
fi

mkdir -p "$PROBE_RUN"
exec > >(tee -a "$PROBE_LOG") 2>&1

restore_hci_preferences() {
  local probe_status=$?
  trap - EXIT INT TERM
  if [[ "$RESTORE_NEEDED" == "1" ]]; then
    if [[ -f "$BACKUP_PLIST" ]]; then
      sudo -n ditto --norsrc --noextattr --noqtn --noacl "$BACKUP_PLIST" "$PREF_PLIST"
    else
      sudo -n defaults delete "$PREF_DOMAIN" HCITraces >/dev/null 2>&1 || true
      if [[ -f "$PREF_PLIST" ]]; then
        local trash_destination="/Users/andy/.Trash/com.apple.MobileBluetooth.debug.probe-$(date -u +%Y%m%dT%H%M%SZ)-$$.plist"
        if ! sudo -n /usr/libexec/PlistBuddy -c Print "$PREF_PLIST" 2>/dev/null | grep -q '='; then
          sudo -n mv "$PREF_PLIST" "$trash_destination"
          sudo -n chown "$(id -u):$(id -g)" "$trash_destination"
        fi
      fi
    fi
    sudo -n killall -30 bluetoothd >/dev/null 2>&1 || true
    print "HCI_RESTORE completed evidence=$PROBE_RUN"
  fi
  exit "$probe_status"
}
trap restore_hci_preferences EXIT INT TERM

print "PROBE_BASELINE packetlogger=absent profile=not_required_by_test"
sudo -v

if sudo -n test -f "$PREF_PLIST"; then
  sudo -n ditto --norsrc --noextattr --noqtn --noacl "$PREF_PLIST" "$BACKUP_PLIST"
  sudo -n chown "$(id -u):$(id -g)" "$BACKUP_PLIST"
else
  touch "$ABSENT_MARKER"
fi

RESTORE_NEEDED=1
sudo -n defaults write "$PREF_DOMAIN" HCITraces -dict \
  StackDebugEnabled -bool true \
  HCILiveTraces -bool true \
  HCIFileTraces -bool true \
  RawAudioTrace -bool true \
  HIDTrace -bool true \
  HCISkipAuth -bool true
sudo -n killall -30 bluetoothd
sleep 2

print "HCI_PROBE enabled=full live=true file=true raw_audio=true hid=true skip_auth=true"
print "AUDIO_PROBE_INSTRUCTION speak_near_remote=true duration_seconds=10"
"$PROBE_BINARY" --packetlogger-audio-probe 10
