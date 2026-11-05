#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
RELEASE_CREDENTIALS_REPO="${RELEASE_CREDENTIALS_REPO:?Set RELEASE_CREDENTIALS_REPO to the readonly credentials checkout}"
MATCH_REPO="${MATCH_REPO:?Set MATCH_REPO to the readonly Match checkout}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:?Set AGE_IDENTITY_FILE to the protected CI age identity}"
ISOLATED_KEYCHAIN_RUNNER="$RELEASE_CREDENTIALS_REPO/run-with-isolated-release-keychain.sh"
SECRETS_VALIDATOR="$RELEASE_CREDENTIALS_REPO/skills/remotemic-notary-secrets/scripts/validate-notary-secrets-repo.sh"
MATCH_VALIDATOR="$MATCH_REPO/skills/apple-signing-match/scripts/validate-signing-repo.sh"
P8_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/AuthKey_JG5HB3CLJ3.p8.github-actions.age"
MATCH_PASSWORD_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/match-password.github-actions.age"
SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/sparkle-ed25519.github-actions.key.age"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  print -u2 "this credential bootstrap is restricted to GitHub Actions"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "L3QHLDRPAY" ]]; then
  print -u2 "refusing to release for an unexpected Apple Developer Team"
  exit 1
fi
if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
  print -u2 "RELEASE_TAG must match Resources/Info.plist"
  exit 1
fi
if [[ "${REMOTE_WEB_RELAY_URL:-}" != wss://?*/ws ]]; then
  print -u2 "REMOTE_WEB_RELAY_URL must be a production wss:// URL ending in /ws"
  exit 1
fi
if ! print -r -- "${EARLY_ACCESS_SERVICE_URL:-}" | rg -q '^https://[^/?#]+/?$'; then
  print -u2 "EARLY_ACCESS_SERVICE_URL must be a production root HTTPS URL"
  exit 1
fi

for required_file in \
  "$AGE_IDENTITY_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" \
  "$SECRETS_VALIDATOR" \
  "$MATCH_VALIDATOR" \
  "$P8_ENCRYPTED_FILE" \
  "$MATCH_PASSWORD_ENCRYPTED_FILE" \
  "$SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE"; do
  if [[ ! -r "$required_file" ]]; then
    print -u2 "required Actions release input is unavailable: $required_file"
    exit 1
  fi
done
if [[ "$(/usr/bin/stat -f '%Lp' "$AGE_IDENTITY_FILE")" != "600" ]]; then
  print -u2 "the protected Actions age identity must have mode 600"
  exit 1
fi

match_checkout_head="$(git -C "$MATCH_REPO" rev-parse HEAD)"
match_main_head="$(git -C "$MATCH_REPO" rev-parse refs/heads/main 2>/dev/null || true)"
if [[ -z "$match_checkout_head" || "$match_main_head" != "$match_checkout_head" ]]; then
  print -u2 "readonly Match checkout must expose local main at its exact pinned HEAD"
  exit 1
fi

"$SECRETS_VALIDATOR" "$RELEASE_CREDENTIALS_REPO"
"$MATCH_VALIDATOR" "$MATCH_REPO"

ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 \
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" \
MATCH_GIT_URL="file://$MATCH_REPO" \
P8_ENCRYPTED_FILE="$P8_ENCRYPTED_FILE" \
MATCH_PASSWORD_ENCRYPTED_FILE="$MATCH_PASSWORD_ENCRYPTED_FILE" \
SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE="$SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" -- "$ROOT/scripts/notarize-release.sh" --all

# 从产物读回构建来源：CI 缓存或复用旧 dist 时，包和 dispatch 的提交会对不上。
# 这一步在签名/公证之后、上传之前，覆盖两个架构的 DMG、安装器与 .app。
EXPECTED_COMMIT="${EXPECTED_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
print -r -- "$EXPECTED_COMMIT" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' || {
  print -u2 "EXPECTED_COMMIT must be a full 40-character lowercase SHA"
  exit 1
}
verified_artifacts=0
for artifact in \
  "$ROOT"/dist/*.dmg(N) "$ROOT"/dist/*Install*.pkg(N) "$ROOT"/dist/SayAll.app(N) \
  "$ROOT"/dist/intel/*.dmg(N) "$ROOT"/dist/intel/*Install*.pkg(N) "$ROOT"/dist/intel/SayAll.app(N); do
  "$ROOT/scripts/verify-release-asset-source.sh" --asset "$artifact" --expected-commit "$EXPECTED_COMMIT" || {
    print -u2 "refusing to publish: ${artifact:t} was not built from $EXPECTED_COMMIT"
    exit 1
  }
  (( verified_artifacts += 1 ))
done
(( verified_artifacts > 0 )) || {
  print -u2 "no built artifact to verify under $ROOT/dist"
  exit 1
}
print "VERIFIED_ARTIFACT_COUNT=$verified_artifacts"

print "GITHUB ACTIONS MAC RELEASE PACKAGE PASS"
print "RELEASE TAG: $RELEASE_TAG"
print "APPLE SILICON OUTPUT: $ROOT/dist"
print "INTEL OUTPUT: $ROOT/dist/intel"
