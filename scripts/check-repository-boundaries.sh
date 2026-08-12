#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

for forbidden_path in \
  Apps/RemoteMicIOS \
  Apps/MobileWeb \
  .github/workflows/ios-ci.yml \
  .github/workflows/web-ci.yml \
  Sources/RemoteMic/DeepSeekCredentialStore.swift \
  Sources/RemoteMic/DeepSeekTextPolishingClient.swift \
  Sources/RemoteMic/ProgrammingTermStore.swift \
  Sources/RemoteMic/PostDictationPolishCoordinator.swift \
  Sources/RemoteMic/PostDictationHUDController.swift \
  Sources/RemoteMic/EarlyAccessClient.swift \
  Sources/RemoteMic/EarlyAccessController.swift \
  Sources/RemoteMic/EarlyAccessCredentialStore.swift \
  Sources/RemoteMic/EarlyAccessEntitlement.swift \
  Tests/RemoteMicTests/DeepSeekCredentialStoreTests.swift \
  Tests/RemoteMicTests/DeepSeekTextPolishingClientTests.swift \
  Tests/RemoteMicTests/ProgrammingTermStoreTests.swift \
  Tests/RemoteMicTests/PostDictationPolishCoordinatorTests.swift \
  Tests/RemoteMicTests/PostDictationHUDControllerTests.swift \
  Tests/RemoteMicTests/EarlyAccessClientTests.swift \
  Tests/RemoteMicTests/EarlyAccessControllerTests.swift \
  Tests/RemoteMicTests/EarlyAccessCredentialStoreTests.swift \
  Tests/RemoteMicTests/EarlyAccessEntitlementTests.swift \
  Tests/RemoteMicTests/EarlyAccessFeatureGateTests.swift \
  Tests/RemoteMicTests/EarlyAccessTestSupport.swift \
  feature/deepseek-post-dictation-mvp \
  feature/early-access-ai-polish \
  Testing/EarlyAccessAIPolish.md \
  Bugs/early-access-keychain-test-contention.md; do
  if [[ -e "$forbidden_path" ]] || {
    [[ -n "$(git ls-files --cached -- "$forbidden_path")" ]] &&
      [[ -z "$(git ls-files --deleted -- "$forbidden_path")" ]]
  }; then
    print -u2 "migrated component path returned to Mac repository: $forbidden_path"
    exit 1
  fi
done

if git grep -n -I -E \
  'DeepSeek|deepseek_post_dictation|post_dictation\.|AI 整理|EarlyAccessController' \
  -- \
  'Sources/RemoteMic/*.swift' \
  'Resources/**' \
  'README*.md' \
  'TODO.md' \
  'feature/**' \
  'Testing/**' \
  'Bugs/**' \
  ':(exclude)Sources/RemoteMic/PrivateFeatureIntegration.swift'; then
  print -u2 "private feature implementation detail returned to the public tree"
  exit 1
fi

print "REPOSITORY BOUNDARY PASS"
