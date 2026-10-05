#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DESTINATION="/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

source "$ROOT/packaging/doubao-driver/install/driver-naming.zsh"
installer_message() { print -r -- "$2"; }
if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
  print -u2 "Refusing to overwrite existing driver: $DESTINATION"
  exit 2
fi
prepare_driver_naming_directory / || { driver_naming_failure unsafe_state_directory; exit 2; }
check_driver_naming_duplicates / "$DESTINATION" || { driver_naming_failure duplicate_driver; exit 2; }
RECORDED_NAMING="$(driver_naming_record)" || { driver_naming_failure invalid_state; exit 2; }
OWNED_APP_FOUND=0
for app in /Applications/SayAll.app "/Applications/Remote Mic.app" /Applications/无线麦.app; do
  if [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)" == com.hd838a.RemoteMic ]]; then
    OWNED_APP_FOUND=1
  fi
done
HISTORICAL_INSTALL=no
if has_driver_naming_history /; then HISTORICAL_INSTALL=yes; fi
SELECTED_NAMING="$(resolve_driver_naming none "$RECORDED_NAMING" "$HISTORICAL_INSTALL")" || {
  driver_naming_failure conflicting_evidence; exit 2
}
SOURCE="$ROOT/dist/MiRemoteV2ch.driver"
DRIVER_DISPLAY_NAME=SayAll
if [[ "$SELECTED_NAMING" == legacy ]]; then
  SOURCE="$ROOT/dist/legacy/MiRemoteV2ch.driver"
  DRIVER_DISPLAY_NAME="MiRemoteV 2ch"
fi
test -d "$SOURCE"
"$ROOT/scripts/verify-doubao-driver.sh" "$SOURCE" "$SELECTED_NAMING"
print "DRIVER_NAMING phase=selected result=ready variant=$SELECTED_NAMING history=$HISTORICAL_INSTALL"

# Keep a failed copy recoverable. No existing HAL driver is replaced here.
if ! ditto --norsrc --noextattr --noqtn --noacl "$SOURCE" "$DESTINATION" || \
   ! chown -R root:wheel "$DESTINATION" || \
   ! find "$DESTINATION" -type d -exec chmod 755 {} \; || \
   ! find "$DESTINATION" -type f -exec chmod 644 {} \; || \
   ! chmod 755 "$DESTINATION/Contents/MacOS/MiRemoteV2ch" || \
   ! codesign --verify --deep --strict "$DESTINATION" || \
   [[ "$(driver_naming_variant "$DESTINATION")" != "$SELECTED_NAMING" ]] || \
   ! commit_driver_naming_record "$SELECTED_NAMING"; then
  if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    FAILED_DRIVER="/var/root/.Trash/MiRemoteV2ch (failed $(/bin/date -u +%Y%m%dT%H%M%SZ)-$$).driver"
    if [[ -L /var/root/.Trash ]] || \
       ! /bin/mkdir -p /var/root/.Trash || \
       ! driver_naming_safe_directory /var/root/.Trash || \
       ! /bin/chmod 700 /var/root/.Trash || \
       ! /bin/mv -n -- "$DESTINATION" "$FAILED_DRIVER"; then
      print -u2 "Installation failed; the failed copy remains at $DESTINATION."
    fi
  fi
  driver_naming_failure driver_installation_failed
  exit 2
fi
print "DRIVER_NAMING phase=installed result=verified variant=$SELECTED_NAMING audio_loaded=unknown"

# The driver is already in place; a failed audio-service restart must not
# abort the script after the real work succeeded.
restart_audio_service() {
  if ! pgrep -qx coreaudiod; then
    print "The system audio service is not running; no restart was needed."
  elif killall coreaudiod; then
    print "Restarted the system audio service."
  else
    print "The driver is installed but the system audio service could not be restarted; restart your Mac to load it."
  fi
}
restart_audio_service
print "Installed: $DESTINATION"
print "Open SayAll, refresh audio devices, then select $DRIVER_DISPLAY_NAME."
