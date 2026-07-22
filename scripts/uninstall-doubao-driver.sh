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
killall coreaudiod
print "Removed: $DESTINATION"
