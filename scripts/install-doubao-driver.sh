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

killall coreaudiod
print "Installed: $DESTINATION"
print "Open 小米遥控器桥接, refresh audio devices, then select MiRemoteV 2ch."
