#!/bin/zsh
set -euo pipefail

DESTINATION="/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

if [[ ! -d "$DESTINATION" ]]; then
  print "Driver is not installed: $DESTINATION"
  exit 0
fi

rm -rf -- "$DESTINATION"
# The driver is already gone; a failed audio-service restart must not abort
# the script after the real work succeeded.
restart_audio_service() {
  if ! pgrep -qx coreaudiod; then
    print "The system audio service is not running; no restart was needed."
  elif killall coreaudiod; then
    print "Restarted the system audio service."
  else
    print "The driver was removed but the system audio service could not be restarted; restart your Mac to finish."
  fi
}
restart_audio_service
print "Removed: $DESTINATION"
