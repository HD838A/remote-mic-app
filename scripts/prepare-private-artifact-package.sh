#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  print -u2 "usage: $0 RELEASE_DIRECTORY OUTPUT_PACKAGE_DIRECTORY TRUSTED_SHA256SUMS_SHA256"
  exit 2
fi

RELEASE_DIRECTORY="${1:A}"
OUTPUT_PACKAGE_DIRECTORY="$2"
TRUSTED_SHA256SUMS_SHA256="$3"
OUTPUT_PARENT="$(cd "${OUTPUT_PACKAGE_DIRECTORY:h}" && pwd)"
OUTPUT_BASENAME="${OUTPUT_PACKAGE_DIRECTORY:t}"

for command_name in jq shasum unzip zipinfo lipo plutil mktemp grep; do
  command -v "$command_name" >/dev/null || {
    print -u2 "required command is unavailable: $command_name"
    exit 2
  }
done
print -r -- "$TRUSTED_SHA256SUMS_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
  print -u2 "trusted checksum manifest digest must be lowercase SHA-256"
  exit 2
}
test -d "$RELEASE_DIRECTORY"
test -f "$RELEASE_DIRECTORY/SHA256SUMS"
test -f "$RELEASE_DIRECTORY/provenance.json"
if [[ -e "$OUTPUT_PACKAGE_DIRECTORY" ]]; then
  print -u2 "output package directory must be absent: $OUTPUT_PACKAGE_DIRECTORY"
  exit 2
fi

ACTUAL_SHA256SUMS_SHA256="$(shasum -a 256 "$RELEASE_DIRECTORY/SHA256SUMS" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256SUMS_SHA256" != "$TRUSTED_SHA256SUMS_SHA256" ]]; then
  print -u2 "checksum manifest digest does not match the trusted value"
  exit 1
fi

EXPECTED_ARCHIVES=(
  SayAllMacroCore.xcframework.zip
  SayAllMacroMacOS.xcframework.zip
  SayAllMacroRemoteMic.xcframework.zip
  SayAllMembershipCore.xcframework.zip
  SayAllMembershipUI.xcframework.zip
  SayAllMacroPlatform_SayAllMacroRemoteMic.bundle.zip
)
EXPECTED_CHECKSUM_PATHS="$(printf './%s\n' "${EXPECTED_ARCHIVES[@]}" | LC_ALL=C sort)"
ACTUAL_CHECKSUM_PATHS="$(awk '{print $2}' "$RELEASE_DIRECTORY/SHA256SUMS" | LC_ALL=C sort)"
if [[ "$ACTUAL_CHECKSUM_PATHS" != "$EXPECTED_CHECKSUM_PATHS" ]]; then
  print -u2 "checksum manifest must name exactly the approved private artifact archives"
  exit 1
fi

if ! jq -e '
  .schema_version == "2" and
  .source_repository == "GetSayAll/sayall-private-platform" and
  (.source_commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.build_tool.commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.build_tool.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  .repository_state.dirty == false and
  .minimum_macos == "13.0" and
  .architectures == ["arm64", "x86_64"] and
  .linkage == "static" and
  .resource_bundles == ["SayAllMacroPlatform_SayAllMacroRemoteMic.bundle"]
' "$RELEASE_DIRECTORY/provenance.json" >/dev/null; then
  print -u2 "private artifact provenance is invalid, dirty, or incompatible"
  exit 1
fi

(
  cd "$RELEASE_DIRECTORY"
  shasum -a 256 -c SHA256SUMS
)

for archive_name in "${EXPECTED_ARCHIVES[@]}"; do
  archive_path="$RELEASE_DIRECTORY/$archive_name"
  test -f "$archive_path"
  if unzip -Z1 "$archive_path" | grep -Eq '(^/|(^|/)\.\.(/|$)|\\)'; then
    print -u2 "archive contains an unsafe path: $archive_name"
    exit 1
  fi
  if zipinfo -l "$archive_path" | awk 'NR > 3 && $1 ~ /^l/ { found=1 } END { exit(found ? 0 : 1) }'; then
    print -u2 "archive contains a symbolic link: $archive_name"
    exit 1
  fi
  if unzip -Z1 "$archive_path" \
      | grep -Eq '(^|/)([^/]+\.(swift|swiftdoc|swiftsourceinfo|private\.swiftinterface|package\.swiftinterface|pem|key|p12|mobileprovision)|[^/]+\.dSYM)(/|$)|(^|/)[^/]+\.swiftmodule$'; then
    print -u2 "archive contains a forbidden source, debug, or credential file: $archive_name"
    exit 1
  fi
  if unzip -p "$archive_path" \
      | LC_ALL=C grep -aE '/Users/[^/[:space:]]+|/private/tmp|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|sk_live_[A-Za-z0-9]{16,}' >/dev/null; then
    print -u2 "archive contains a local path or credential-like material: $archive_name"
    exit 1
  fi
done

STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASENAME}.staging.XXXXXX")"
PACKAGE_COMPLETED=0
report_incomplete_package() {
  local status="$?"
  if [[ "$status" -ne 0 && "$PACKAGE_COMPLETED" -ne 1 ]]; then
    print -u2 "preparation failed; preserved staging directory: $STAGING_DIRECTORY"
  fi
}
trap report_incomplete_package EXIT

mkdir -p "$STAGING_DIRECTORY/Artifacts" "$STAGING_DIRECTORY/Resources"
for module_name in \
  SayAllMembershipCore \
  SayAllMembershipUI \
  SayAllMacroCore \
  SayAllMacroMacOS \
  SayAllMacroRemoteMic; do
  unzip -q "$RELEASE_DIRECTORY/$module_name.xcframework.zip" \
    -d "$STAGING_DIRECTORY/Artifacts"
  framework="$STAGING_DIRECTORY/Artifacts/$module_name.xcframework/macos-arm64_x86_64/$module_name.framework"
  binary="$framework/$module_name"
  test -f "$binary"
  lipo "$binary" -verify_arch arm64 x86_64
  test "$(plutil -extract MinimumOSVersion raw -o - "$framework/Info.plist")" = "13.0"
done
unzip -q "$RELEASE_DIRECTORY/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle.zip" \
  -d "$STAGING_DIRECTORY/Resources"
test -f "$STAGING_DIRECTORY/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle/Contents/Resources/en.lproj/Localizable.strings"
test -f "$STAGING_DIRECTORY/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle/Contents/Resources/zh-Hans.lproj/Localizable.strings"

cat > "$STAGING_DIRECTORY/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SayAllPrivateArtifacts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SayAllMembershipCore", targets: ["SayAllMembershipCore"]),
        .library(name: "SayAllMembershipUI", targets: ["SayAllMembershipCore", "SayAllMembershipUI"]),
        .library(
            name: "SayAllMacroRemoteMic",
            targets: ["SayAllMacroCore", "SayAllMacroMacOS", "SayAllMacroRemoteMic"]
        ),
    ],
    targets: [
        .binaryTarget(name: "SayAllMembershipCore", path: "Artifacts/SayAllMembershipCore.xcframework"),
        .binaryTarget(name: "SayAllMembershipUI", path: "Artifacts/SayAllMembershipUI.xcframework"),
        .binaryTarget(name: "SayAllMacroCore", path: "Artifacts/SayAllMacroCore.xcframework"),
        .binaryTarget(name: "SayAllMacroMacOS", path: "Artifacts/SayAllMacroMacOS.xcframework"),
        .binaryTarget(name: "SayAllMacroRemoteMic", path: "Artifacts/SayAllMacroRemoteMic.xcframework"),
    ]
)
SWIFT

cp "$RELEASE_DIRECTORY/provenance.json" "$STAGING_DIRECTORY/provenance.json"
cp "$RELEASE_DIRECTORY/SHA256SUMS" "$STAGING_DIRECTORY/SHA256SUMS"
(
  cd "$STAGING_DIRECTORY"
  {
    printf '%s\n' Package.swift provenance.json SHA256SUMS
    find Artifacts Resources -type f -print
  } | LC_ALL=C sort | while IFS= read -r file; do
    shasum -a 256 "$file"
  done > PREPARED_SHA256SUMS
)
PREPARED_MANIFEST_SHA256="$(shasum -a 256 "$STAGING_DIRECTORY/PREPARED_SHA256SUMS" | awk '{print $1}')"
jq -n \
  --arg sourceCommit "$(jq -r '.source_commit' "$RELEASE_DIRECTORY/provenance.json")" \
  --arg checksumsSHA256 "$ACTUAL_SHA256SUMS_SHA256" \
  --arg preparedManifestSHA256 "$PREPARED_MANIFEST_SHA256" \
  '{
    schemaVersion: 1,
    sourceCommit: $sourceCommit,
    checksumsSHA256: $checksumsSHA256,
    preparedManifestSHA256: $preparedManifestSHA256,
    repositoryDirty: false,
    minimumMacOS: "13.0",
    architectures: ["arm64", "x86_64"]
  }' > "$STAGING_DIRECTORY/private-artifact-package.json"

if [[ -e "$OUTPUT_PACKAGE_DIRECTORY" ]]; then
  print -u2 "output path appeared during preparation; preserved staging directory: $STAGING_DIRECTORY"
  exit 1
fi
mv "$STAGING_DIRECTORY" "$OUTPUT_PACKAGE_DIRECTORY"
PACKAGE_COMPLETED=1
trap - EXIT
print "$OUTPUT_PACKAGE_DIRECTORY"
