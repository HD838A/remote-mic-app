#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"

OPUS_VERSION="1.6.1"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
BUILD_ROOT="$ROOT/.build/apple-remote-opus/$RELEASE_VARIANT"
SOURCE_ARCHIVE="$BUILD_ROOT/opus-$OPUS_VERSION.tar.gz"
SOURCE_ROOT="$BUILD_ROOT/opus-$OPUS_VERSION"
INSTALL_ROOT="$BUILD_ROOT/install"
OUTPUT="$INSTALL_ROOT/lib/libopus.0.dylib"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

if [[ "$(uname -m)" != "$RELEASE_ARCH" ]]; then
  print -u2 "Apple Remote Opus must be built on a $RELEASE_ARCH host for $RELEASE_VARIANT"
  exit 1
fi

if [[ -f "$OUTPUT" ]]; then
  OPUS_ARCHS="$(lipo -archs "$OUTPUT")"
  OPUS_MINOS="$(xcrun vtool -show-build "$OUTPUT" | awk '/minos / { print $2; exit }')"
  if [[ " $OPUS_ARCHS " == *" $RELEASE_ARCH "* && "${OPUS_MINOS%%.*}" -le "$RELEASE_MIN_SYSTEM_MAJOR" ]]; then
    install_name_tool -id @rpath/libopus.0.dylib "$OUTPUT"
    print "$OUTPUT"
    exit 0
  fi
fi

if [[ -e "$BUILD_ROOT" ]]; then
  USER_DIRECTORY="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
  TRASH_DESTINATION="$USER_DIRECTORY/.Trash/apple-remote-opus-${RELEASE_VARIANT}.$(date -u +%Y%m%dT%H%M%SZ).$$"
  mv "$BUILD_ROOT" "$TRASH_DESTINATION"
fi

mkdir -p "$BUILD_ROOT"
curl --fail --location --silent --show-error \
  "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-$OPUS_VERSION.tar.gz" \
  --output "$SOURCE_ARCHIVE"
ACTUAL_SHA256="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$OPUS_SHA256" ]]; then
  print -u2 "Opus source checksum mismatch"
  exit 1
fi
tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_ROOT"
mkdir -p "$INSTALL_ROOT"
(
  cd "$SOURCE_ROOT"
  export MACOSX_DEPLOYMENT_TARGET="$RELEASE_MIN_SYSTEM_VERSION"
  export SDKROOT="$SDK_PATH"
  CC="$(xcrun --find clang)" \
  CFLAGS="-target $RELEASE_TRIPLE -isysroot $SDK_PATH -O2" \
  LDFLAGS="-target $RELEASE_TRIPLE -isysroot $SDK_PATH -Wl,-dead_strip" \
    ./configure \
      --prefix="$INSTALL_ROOT" \
      --disable-doc \
      --disable-extra-programs \
      --disable-static \
      --enable-shared
  make -j "$(sysctl -n hw.logicalcpu)"
  mkdir -p "$INSTALL_ROOT/lib"
  ditto --norsrc --noextattr --noqtn --noacl \
    "$SOURCE_ROOT/.libs/libopus.0.dylib" "$OUTPUT"
)

test -f "$OUTPUT"
install_name_tool -id @rpath/libopus.0.dylib "$OUTPUT"
test "$(lipo -archs "$OUTPUT")" = "$RELEASE_ARCH"
xcrun vtool -show-build "$OUTPUT" | rg -Fq "minos $RELEASE_MIN_SYSTEM_VERSION"
print "$OUTPUT"
