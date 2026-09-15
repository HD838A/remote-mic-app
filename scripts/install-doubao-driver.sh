#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/dist/MiRemoteV2ch.driver"
DESTINATION="/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

test -d "$SOURCE"
"$ROOT/scripts/verify-doubao-driver.sh" "$SOURCE"
if [[ -e "$DESTINATION" ]]; then
  print -u2 "Refusing to overwrite existing driver: $DESTINATION"
  exit 2
fi

ditto --norsrc --noextattr --noqtn --noacl "$SOURCE" "$DESTINATION"
chown -R root:wheel "$DESTINATION"
find "$DESTINATION" -type d -exec chmod 755 {} \;
find "$DESTINATION" -type f -exec chmod 644 {} \;
chmod 755 "$DESTINATION/Contents/MacOS/MiRemoteV2ch"
codesign --verify --deep --strict "$DESTINATION"

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
print "Open Remote Mic, refresh audio devices, then select MiRemoteV 2ch."
