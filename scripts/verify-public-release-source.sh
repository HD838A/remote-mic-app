#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="${REPOSITORY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPOSITORY="${GITHUB_REPOSITORY:-HD838A/remote-mic-app}"
GH_BIN="${GH_BIN:-gh}"
SOURCE_BRANCH="${1:-}"
EXPECTED_COMMIT="${2:-}"
EXPECTED_VERSION="${3:-}"
CHECKOUT_MODE="${RELEASE_SOURCE_CHECKOUT_MODE:-exact}"
REMOTE_MODE="${RELEASE_SOURCE_REMOTE_MODE:-exact}"
EXPECTED_BASE_TAG="${RELEASE_SOURCE_EXPECTED_BASE_TAG:-}"
EXPECTED_BASE_COMMIT="${RELEASE_SOURCE_EXPECTED_BASE_COMMIT:-}"
REQUIRE_CURRENT_STABLE_BASE="${RELEASE_SOURCE_REQUIRE_CURRENT_STABLE_BASE:-1}"

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "usage: $0 <main|hotfix/vX.Y.Z> <40-character-source-commit> [version]" >&2
  exit 2
fi
[[ "$REPOSITORY" == "HD838A/remote-mic-app" ]] || {
  echo "Public release source verification is restricted to HD838A/remote-mic-app" >&2
  exit 1
}
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "release source commit must be a full 40-character SHA" >&2
  exit 1
}
case "$CHECKOUT_MODE" in
  exact|detached|none) ;;
  *) echo "RELEASE_SOURCE_CHECKOUT_MODE must be exact, detached, or none" >&2; exit 2 ;;
esac
case "$REMOTE_MODE" in
  exact|published) ;;
  *) echo "RELEASE_SOURCE_REMOTE_MODE must be exact or published" >&2; exit 2 ;;
esac
[[ "$REQUIRE_CURRENT_STABLE_BASE" == 0 || "$REQUIRE_CURRENT_STABLE_BASE" == 1 ]] || {
  echo "RELEASE_SOURCE_REQUIRE_CURRENT_STABLE_BASE must be 0 or 1" >&2
  exit 2
}
for command_name in git jq plutil "$GH_BIN"; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing required command: $command_name" >&2
    exit 1
  }
done

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  echo "release source verification requires a clean worktree" >&2
  exit 1
}
case "$CHECKOUT_MODE" in
  exact)
    [[ "$(git branch --show-current)" == "$SOURCE_BRANCH" &&
       "$(git rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] || {
      echo "release source must be checked out on the exact source branch and commit" >&2
      exit 1
    }
    ;;
  detached)
    [[ -z "$(git branch --show-current)" &&
       "$(git rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] || {
      echo "workflow release source must be a detached checkout of the exact source commit" >&2
      exit 1
    }
    ;;
  none)
    ;;
esac

if [[ -z "$EXPECTED_VERSION" ]]; then
  EXPECTED_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
fi
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "release source version is invalid" >&2
  exit 1
}

case "$SOURCE_BRANCH" in
  main)
    SOURCE_KIND=main
    ;;
  hotfix/v*)
    [[ "$SOURCE_BRANCH" =~ ^hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo "Hotfix release branches must use the exact hotfix/vX.Y.Z format" >&2
      exit 1
    }
    [[ "$SOURCE_BRANCH" == "hotfix/v$EXPECTED_VERSION" ]] || {
      echo "Hotfix branch version must match Resources/Info.plist" >&2
      exit 1
    }
    SOURCE_KIND=hotfix
    ;;
  *)
    echo "public releases accept only main or hotfix/vX.Y.Z; release-main and feature branches are frozen out" >&2
    exit 1
    ;;
esac

git fetch --no-tags origin "$SOURCE_BRANCH"
REMOTE_COMMIT="$(git rev-parse "origin/$SOURCE_BRANCH")"
if [[ "$SOURCE_KIND" == main && "$REMOTE_MODE" == published ]]; then
  git merge-base --is-ancestor "$EXPECTED_COMMIT" "$REMOTE_COMMIT" || {
    echo "published main source is not contained in current origin/main" >&2
    exit 1
  }
else
  [[ "$REMOTE_COMMIT" == "$EXPECTED_COMMIT" ]] || {
    echo "release source commit must exactly match origin/$SOURCE_BRANCH" >&2
    exit 1
  }
fi

SOURCE_BASE_TAG=""
SOURCE_BASE_COMMIT=""
if [[ "$SOURCE_KIND" == hotfix ]]; then
  if [[ "$REQUIRE_CURRENT_STABLE_BASE" == 1 || -z "$EXPECTED_BASE_TAG" ]]; then
    stable_release="$($GH_BIN api "repos/$REPOSITORY/releases/latest")" || {
      echo "unable to resolve the current stable latest Release" >&2
      exit 1
    }
    current_stable_tag="$(printf '%s\n' "$stable_release" | jq -r '.tag_name')"
    printf '%s\n' "$stable_release" | jq -e \
      --arg tag "$current_stable_tag" \
      '.tag_name == $tag and ($tag | test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and .draft == false and .prerelease == false' >/dev/null || {
      echo "releases/latest is not a formal stable Release" >&2
      exit 1
    }
    if [[ -n "$EXPECTED_BASE_TAG" && "$current_stable_tag" != "$EXPECTED_BASE_TAG" ]]; then
      echo "Hotfix stable baseline changed: expected $EXPECTED_BASE_TAG, found $current_stable_tag" >&2
      exit 1
    fi
    SOURCE_BASE_TAG="$current_stable_tag"
  else
    SOURCE_BASE_TAG="$EXPECTED_BASE_TAG"
  fi

  [[ "$SOURCE_BASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Hotfix stable baseline Tag is invalid" >&2
    exit 1
  }
  remote_tag_refs="$(git ls-remote origin "refs/tags/$SOURCE_BASE_TAG" "refs/tags/$SOURCE_BASE_TAG^{}")" || {
    echo "unable to resolve Hotfix stable baseline Tag" >&2
    exit 1
  }
  SOURCE_BASE_COMMIT="$(printf '%s\n' "$remote_tag_refs" | /usr/bin/awk '$2 ~ /\^\{\}$/ {print $1; found=1; exit} $2 !~ /\^\{\}$/ {fallback=$1} END {if (!found && fallback != "") print fallback}')"
  [[ "$SOURCE_BASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Hotfix stable baseline Tag has no resolvable commit" >&2
    exit 1
  }
  if [[ -n "$EXPECTED_BASE_COMMIT" && "$SOURCE_BASE_COMMIT" != "$EXPECTED_BASE_COMMIT" ]]; then
    echo "Hotfix stable baseline Commit changed" >&2
    exit 1
  fi
  git cat-file -e "$SOURCE_BASE_COMMIT^{commit}" 2>/dev/null || git fetch --no-tags origin "$SOURCE_BASE_COMMIT"
  git merge-base --is-ancestor "$SOURCE_BASE_COMMIT" "$EXPECTED_COMMIT" || {
    echo "Hotfix source is not derived from the current stable Tag" >&2
    exit 1
  }
  [[ "$(git rev-list --min-parents=2 --count "$SOURCE_BASE_COMMIT..$EXPECTED_COMMIT")" == 0 ]] || {
    echo "Hotfix source must remain linear after the stable Tag" >&2
    exit 1
  }

  base_version="${SOURCE_BASE_TAG#v}"
  IFS=. read -r base_major base_minor base_patch <<< "$base_version"
  IFS=. read -r target_major target_minor target_patch <<< "$EXPECTED_VERSION"
  [[ "$target_major" == "$base_major" && "$target_minor" == "$base_minor" &&
     "$target_patch" -gt "$base_patch" ]] || {
    echo "Hotfix version must be a higher patch version in the current stable series" >&2
    exit 1
  }
else
  [[ -z "$EXPECTED_BASE_TAG" && -z "$EXPECTED_BASE_COMMIT" ]] || {
    echo "main releases must not declare a Hotfix stable baseline" >&2
    exit 1
  }
fi

emit_output() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$value"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

emit_output source_branch "$SOURCE_BRANCH"
emit_output source_kind "$SOURCE_KIND"
emit_output source_commit "$EXPECTED_COMMIT"
emit_output source_version "$EXPECTED_VERSION"
emit_output source_base_tag "$SOURCE_BASE_TAG"
emit_output source_base_commit "$SOURCE_BASE_COMMIT"
