#!/bin/zsh
set -euo pipefail
umask 077

ROOT="${0:A:h:h}"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-L3QHLDRPAY}"
RELEASE_CREDENTIALS_REPO="${RELEASE_CREDENTIALS_REPO:?Set RELEASE_CREDENTIALS_REPO to the readonly credentials checkout}"
MATCH_REPO="${MATCH_REPO:?Set MATCH_REPO to the readonly Match checkout}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:?Set AGE_IDENTITY_FILE to the protected CI age identity}"
ISOLATED_KEYCHAIN_RUNNER="$RELEASE_CREDENTIALS_REPO/run-with-isolated-release-keychain.sh"
SECRETS_VALIDATOR="$RELEASE_CREDENTIALS_REPO/skills/remotemic-notary-secrets/scripts/validate-notary-secrets-repo.sh"
MATCH_VALIDATOR="$MATCH_REPO/skills/apple-signing-match/scripts/validate-signing-repo.sh"
P8_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/AuthKey_JG5HB3CLJ3.p8.github-actions.age"
MATCH_PASSWORD_ENCRYPTED_FILE="$RELEASE_CREDENTIALS_REPO/match-password.github-actions.age"

if [[ "$#" -ne 0 ]]; then
  print -u2 "usage: $0"
  exit 1
fi
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  print -u2 "this credential bootstrap is restricted to GitHub Actions"
  exit 1
fi
if [[ "$EXPECTED_DEVELOPER_TEAM_ID" != "L3QHLDRPAY" ]]; then
  print -u2 "refusing to package a preview for an unexpected Apple Developer Team"
  exit 1
fi

for required_file in \
  "$AGE_IDENTITY_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" \
  "$SECRETS_VALIDATOR" \
  "$MATCH_VALIDATOR" \
  "$P8_ENCRYPTED_FILE" \
  "$MATCH_PASSWORD_ENCRYPTED_FILE"; do
  if [[ ! -r "$required_file" ]]; then
    print -u2 "required Actions preview input is unavailable: $required_file"
    exit 1
  fi
done
if [[ "$(/usr/bin/stat -f '%Lp' "$AGE_IDENTITY_FILE")" != "600" ]]; then
  print -u2 "the protected Actions age identity must have mode 600"
  exit 1
fi

"$SECRETS_VALIDATOR" "$RELEASE_CREDENTIALS_REPO"
"$MATCH_VALIDATOR" "$MATCH_REPO"

ALLOW_ISOLATED_RELEASE_KEYCHAIN=1 \
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" \
MATCH_GIT_URL="file://$MATCH_REPO" \
P8_ENCRYPTED_FILE="$P8_ENCRYPTED_FILE" \
MATCH_PASSWORD_ENCRYPTED_FILE="$MATCH_PASSWORD_ENCRYPTED_FILE" \
  "$ISOLATED_KEYCHAIN_RUNNER" -- \
    env GENERATE_SPARKLE_UPDATE=0 "$ROOT/scripts/notarize-release.sh"

print "GITHUB ACTIONS SIGNED MAC PREVIEW PASS"
print "RELEASE VARIANT: ${RELEASE_VARIANT:-apple-silicon}"
