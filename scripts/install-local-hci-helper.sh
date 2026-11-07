#!/bin/zsh
# Maintained installer for the fork's signed local HCI helper. No capture is
# started here. The app acquires a live-only lease only after explicit enablement.
set -euo pipefail
umask 077
[[ "$#" == 1 ]] || { print -u2 'usage: install-local-hci-helper.sh /absolute/SayAll.app'; exit 2; }
APP="${1:A}"
LABEL=com.hd838a.SayAll.AppleRemoteHCIService
SOURCE="$APP/Contents/Helpers/SayAllAppleRemoteHCIService"
DESTINATION="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
[[ "$APP" == /* && "$APP" == *.app && -f "$SOURCE" && ! -L "$SOURCE" ]] || exit 2
[[ "$EUID" == 0 ]] || exec sudo "$0" "$APP"

team() { /usr/bin/codesign -dvv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'; }
identifier() { /usr/bin/codesign -dvv "$1" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p'; }
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/codesign --verify --strict "$SOURCE"
APP_TEAM="$(team "$APP")"
[[ "$APP_TEAM" != '' && "$APP_TEAM" != 'not set' && "$(team "$SOURCE")" == "$APP_TEAM" ]]
[[ "$(identifier "$APP")" == com.hd838a.RemoteMic && "$(identifier "$SOURCE")" == "$LABEL" ]]

# Never replace an upstream/other-team helper or follow a redirected destination.
[[ ! -L /Library/PrivilegedHelperTools && ! -L /Library/LaunchDaemons ]]
[[ ! -L "$DESTINATION" && ! -L "$PLIST" ]]
if [[ -e "$DESTINATION" ]]; then
  /usr/bin/codesign --verify --strict "$DESTINATION"
  [[ "$(team "$DESTINATION")" == "$APP_TEAM" && "$(identifier "$DESTINATION")" == "$LABEL" ]]
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  "$DESTINATION" --restore
fi

STAGE="$(/usr/bin/mktemp -d /private/tmp/sayall-hci-install.XXXXXX)"
trap '/bin/rm -rf -- "$STAGE"' EXIT
/usr/bin/ditto --norsrc --noextattr "$SOURCE" "$STAGE/helper"
/usr/bin/codesign --verify --strict "$STAGE/helper"
[[ "$(team "$STAGE/helper")" == "$APP_TEAM" && "$(identifier "$STAGE/helper")" == "$LABEL" ]]
/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
/usr/bin/install -o root -g wheel -m 755 "$STAGE/helper" "$DESTINATION"
cat > "$STAGE/service.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$DESTINATION</string></array>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
/usr/bin/plutil -lint "$STAGE/service.plist"
/usr/bin/install -o root -g wheel -m 644 "$STAGE/service.plist" "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
/bin/launchctl print "system/$LABEL" >/dev/null
print 'Local HCI helper installed; capture remains disabled until the app requests a lease.'
