#!/bin/zsh

if [[ -z "${ROOT:-}" ]]; then
  print -u2 "release-variant.sh requires ROOT"
  return 1
fi

RELEASE_VARIANT="${RELEASE_VARIANT:-apple-silicon}"

case "$RELEASE_VARIANT" in
  apple-silicon)
    RELEASE_ARCH="arm64"
    RELEASE_TRIPLE="arm64-apple-macosx14.0"
    RELEASE_MIN_SYSTEM_VERSION="14.0"
    RELEASE_MIN_SYSTEM_MAJOR="14"
    RELEASE_OUTPUT_DIR="$ROOT/dist"
    RELEASE_ASSET_SUFFIX=""
    RELEASE_APPCAST_NAME="appcast.xml"
    RELEASE_FEED_URL="https://download.sayall.app/mac/channels/stable/appcast.xml"
    RELEASE_INSTALL_PACKAGE_NAME="Install Remote Mic.pkg"
    RELEASE_UNINSTALL_PACKAGE_NAME="Uninstall Remote Mic.pkg"
    RELEASE_CONFIG_PLIST="$ROOT/packaging/release-variants/apple-silicon.plist"
    RELEASE_WORK_SUFFIX=""
    RELEASE_LABEL="Apple Silicon"
    ;;
  intel)
    RELEASE_ARCH="x86_64"
    RELEASE_TRIPLE="x86_64-apple-macosx13.0"
    RELEASE_MIN_SYSTEM_VERSION="13.0"
    RELEASE_MIN_SYSTEM_MAJOR="13"
    RELEASE_OUTPUT_DIR="$ROOT/dist/intel"
    RELEASE_ASSET_SUFFIX="-Intel"
    RELEASE_APPCAST_NAME="appcast-intel.xml"
    RELEASE_FEED_URL="https://download.sayall.app/mac/channels/stable/appcast-intel.xml"
    RELEASE_INSTALL_PACKAGE_NAME="Install Remote Mic Intel.pkg"
    RELEASE_UNINSTALL_PACKAGE_NAME="Uninstall Remote Mic Intel.pkg"
    RELEASE_CONFIG_PLIST="$ROOT/packaging/release-variants/intel.plist"
    RELEASE_WORK_SUFFIX="-intel"
    RELEASE_LABEL="Intel"
    ;;
  *)
    print -u2 "RELEASE_VARIANT must be apple-silicon or intel"
    return 1
    ;;
esac

test -f "$RELEASE_CONFIG_PLIST"
export RELEASE_VARIANT
