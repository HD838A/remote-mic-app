#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$ROOT/dist"
PLIST="$ROOT/Resources/Info.plist"
DISPLAY_NAME="Remote Mic"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$PLIST")"
APP="$OUTPUT_DIR/$DISPLAY_NAME.app"
INSTALL_PACKAGE="$OUTPUT_DIR/Install Remote Mic.pkg"
UNINSTALL_PACKAGE="$OUTPUT_DIR/Uninstall Remote Mic.pkg"
DMG="$OUTPUT_DIR/Remote-Mic-$VERSION.dmg"
UPDATE_ZIP="$OUTPUT_DIR/Remote-Mic-$VERSION.zip"
APPCAST="$OUTPUT_DIR/appcast.xml"
ZIP_BASENAME="${UPDATE_ZIP:t}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY to a Developer ID Application identity}"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:?Set INSTALLER_SIGNING_IDENTITY to a Developer ID Installer identity}"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:?Set SPARKLE_PRIVATE_KEY_FILE to the restricted local EdDSA key file}"
NOTARY_PROFILE="${NOTARY_PROFILE:-RemoteMic-notary}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"
DOWNLOAD_PREFIX="https://github.com/HD838A/remote-mic-app/releases/latest/download/"
RELEASE_PAGE="https://github.com/HD838A/remote-mic-app/releases/tag/v$VERSION"
GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: CODE_SIGN_IDENTITY=... INSTALLER_SIGNING_IDENTITY=... SPARKLE_PRIVATE_KEY_FILE=... $0"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "L3QHLDRPAY" ]]; then
  print -u2 "refusing to release for an unexpected Apple Developer Team"
  exit 1
fi
if [[ "$CODE_SIGN_IDENTITY" != "Developer ID Application: "* ]]; then
  print -u2 "CODE_SIGN_IDENTITY must name a Developer ID Application identity"
  exit 1
fi
if [[ "$INSTALLER_SIGNING_IDENTITY" != "Developer ID Installer: "* ]]; then
  print -u2 "INSTALLER_SIGNING_IDENTITY must name a Developer ID Installer identity"
  exit 1
fi
if [[ ! -r "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  print -u2 "SPARKLE_PRIVATE_KEY_FILE is not readable"
  exit 1
fi
for command in codesign ditto security xcrun; do
  command -v "$command" >/dev/null 2>&1 || {
    print -u2 "Missing required command: $command"
    exit 1
  }
done
test -x "$GENERATE_APPCAST"
test -x "$SIGN_UPDATE"
NOTARY_KEYCHAIN_ARGS=()
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  test -f "$NOTARY_KEYCHAIN"
  NOTARY_KEYCHAIN_ARGS=(--keychain "$NOTARY_KEYCHAIN")
fi
if ! security find-identity -v -p codesigning | rg -Fq "\"$CODE_SIGN_IDENTITY\""; then
  print -u2 "Developer ID Application identity is unavailable in the local keychain"
  exit 1
fi
if ! security find-identity -v -p basic | rg -Fq "\"$INSTALLER_SIGNING_IDENTITY\""; then
  print -u2 "Developer ID Installer identity is unavailable in the local keychain"
  exit 1
fi

WORK_DIR="$(/usr/bin/mktemp -d /private/tmp/remotemic-notarize-release.XXXXXX)"
APP_NOTARY_ZIP="$WORK_DIR/Remote-Mic-$VERSION-notarization.zip"
SPARKLE_ARCHIVES="$WORK_DIR/sparkle-archives"

cleanup() {
  case "$WORK_DIR" in
    /private/tmp/remotemic-notarize-release.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) print -u2 "refusing to clean unexpected notarization work path: $WORK_DIR" ;;
  esac
}
trap cleanup EXIT

notarize() {
  local artifact="$1"
  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    "${NOTARY_KEYCHAIN_ARGS[@]}" \
    --wait
}

staple_and_validate() {
  local artifact="$1"
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"
}

export CODE_SIGN_IDENTITY
export INSTALLER_SIGNING_IDENTITY
export EXPECTED_DEVELOPER_TEAM_ID
export REQUIRE_DEVELOPER_ID_SIGNING=1
export REQUIRE_NOTARIZATION=0

"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/verify-app.sh" "$APP"

/usr/bin/ditto -c -k --keepParent "$APP" "$APP_NOTARY_ZIP"
notarize "$APP_NOTARY_ZIP"
staple_and_validate "$APP"
REQUIRE_NOTARIZATION=1 "$ROOT/scripts/verify-app.sh" "$APP"

"$ROOT/scripts/build-doubao-driver.sh"
"$ROOT/scripts/build-doubao-driver-pkg.sh"

notarize "$INSTALL_PACKAGE"
staple_and_validate "$INSTALL_PACKAGE"
REQUIRE_NOTARIZATION=1 "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$INSTALL_PACKAGE" install

notarize "$UNINSTALL_PACKAGE"
staple_and_validate "$UNINSTALL_PACKAGE"
REQUIRE_NOTARIZATION=1 "$ROOT/scripts/verify-doubao-driver-pkg.sh" "$UNINSTALL_PACKAGE" uninstall

BUILD_COMPONENTS=0 "$ROOT/scripts/build-dmg.sh"
notarize "$DMG"
staple_and_validate "$DMG"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256"
)
REQUIRE_NOTARIZATION=1 "$ROOT/scripts/verify-dmg.sh" "$DMG"

case "$UPDATE_ZIP" in
  "$OUTPUT_DIR"/Remote-Mic-*.zip) ;;
  *) print -u2 "refusing to replace unexpected Sparkle archive: $UPDATE_ZIP"; exit 1 ;;
esac
case "$APPCAST" in
  "$OUTPUT_DIR"/appcast.xml) ;;
  *) print -u2 "refusing to replace unexpected appcast path: $APPCAST"; exit 1 ;;
esac
/bin/rm -f -- "$UPDATE_ZIP" "$APPCAST"
/usr/bin/ditto -c -k --keepParent "$APP" "$UPDATE_ZIP"
/bin/mkdir -p "$SPARKLE_ARCHIVES"
/usr/bin/ditto --norsrc --noqtn --noacl "$UPDATE_ZIP" "$SPARKLE_ARCHIVES/$ZIP_BASENAME"
"$GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "$RELEASE_PAGE" \
  --versions "$BUILD" \
  --maximum-versions 1 \
  -o "$APPCAST" \
  "$SPARKLE_ARCHIVES"

ENCLOSURE_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -n 1)"
test -n "$ENCLOSURE_SIGNATURE"
rg -Fq "url=\"$DOWNLOAD_PREFIX$ZIP_BASENAME\"" "$APPCAST"
rg -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"
"$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$UPDATE_ZIP" "$ENCLOSURE_SIGNATURE"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$APPCAST"
"$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "$APPCAST"

print "NOTARIZED RELEASE READY"
print "DMG: $DMG"
print "SHA256: $DMG.sha256"
print "INSTALL PACKAGE: $INSTALL_PACKAGE"
print "UNINSTALL PACKAGE: $UNINSTALL_PACKAGE"
print "SPARKLE ZIP: $UPDATE_ZIP"
print "APPCAST: $APPCAST"
