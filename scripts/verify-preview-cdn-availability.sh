#!/usr/bin/env bash
set -euo pipefail
umask 077

TAG="${1:-}"
BUILD="${2:-}"
CDN_BASE_URL="https://download.sayall.app/mac/releases"

if [[ ( "$#" -ne 2 && ( "$#" -ne 3 || "${3:-}" != --contract-only ) ) || ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 <preview-tag> <build>" >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || {
  echo "Missing required command: curl" >&2
  exit 1
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
capability_file="$(mktemp)"
cleanup() {
  mkdir -p "$HOME/.Trash"
  mv "$capability_file" "$HOME/.Trash/sayall-cdn-contract.$$.${RANDOM}.json"
}
trap cleanup EXIT
# A route-level 404 proves availability only after the deployed router confirms
# that it understands this exact public contract.
curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
  "https://download.sayall.app/mac/release-contract.json" --output "$capability_file"
python3 "$ROOT/scripts/release-assets.py" check-capability "$capability_file"
[[ "${3:-}" != --contract-only ]] || exit 0
payload_names="$(python3 "$ROOT/scripts/release-assets.py" names "${TAG#v}" "$BUILD")"

probe_status() {
  local method="$1" url="$2" http_code curl_status
  if [[ "$method" == HEAD ]]; then
    if http_code="$(curl --silent --show-error --head \
        --connect-timeout 10 --max-time 30 --retry 2 --retry-all-errors \
        --output /dev/null --write-out '%{http_code}' "$url")"; then
      curl_status=0
    else
      curl_status=$?
    fi
  else
    if http_code="$(curl --silent --show-error \
        --connect-timeout 10 --max-time 30 --retry 2 --retry-all-errors \
        --header 'Range: bytes=0-0' --output /dev/null --write-out '%{http_code}' "$url")"; then
      curl_status=0
    else
      curl_status=$?
    fi
  fi
  if (( curl_status != 0 )) || [[ ! "$http_code" =~ ^[0-9]{3}$ ]] || [[ "$http_code" == 000 ]]; then
    echo "unable to determine CDN occupancy for $url (curl exit $curl_status, HTTP ${http_code:-unknown})" >&2
    return 1
  fi
  case "$http_code" in
    404)
      return 0
      ;;
    2??|3??)
      echo "CDN path is already occupied: $url (HTTP $http_code)" >&2
      return 42
      ;;
    405|501)
      return 43
      ;;
    *)
      echo "CDN occupancy check failed closed for $url (HTTP $http_code)" >&2
      return 1
      ;;
  esac
}

while IFS= read -r name; do
  url="$CDN_BASE_URL/$TAG/$name"
  status=0
  probe_status HEAD "$url" || status=$?
  if (( status == 43 )); then
    status=0
    probe_status GET "$url" || status=$?
  fi
  case "$status" in
    0)
      ;;
    42)
      exit 42
      ;;
    *)
      exit 1
      ;;
  esac
done <<< "$payload_names"

echo "PREVIEW CDN PATHS AVAILABLE: $TAG"
