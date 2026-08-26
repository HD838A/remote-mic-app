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
  "$ISOLATED_KEYCHAIN_RUNNER" -- "$ROOT/scripts/package-macos-release-variants.sh"

print "GITHUB ACTIONS MAC RELEASE PACKAGE PASS"
print "RELEASE TAG: $RELEASE_TAG"
print "APPLE SILICON OUTPUT: $ROOT/dist"
print "INTEL OUTPUT: $ROOT/dist/intel"
