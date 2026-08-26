#!/usr/bin/env bash
set -euo pipefail
umask 077

TAG="${1:-}"
CDN_BASE_URL="https://download.sayall.app/mac/releases"

if [[ "$#" -ne 1 || ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <preview-tag>" >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || {
  echo "Missing required command: curl" >&2
  exit 1
}

version="${TAG#v}"
payload_names=(
  "Remote-Mic-$version-Intel-Uninstaller.pkg"
  "Remote-Mic-$version-Intel.dmg"
  "Remote-Mic-$version-Intel.zip"
  "Remote-Mic-$version-Uninstaller.pkg"
  "Remote-Mic-$version.dmg"
  "Remote-Mic-$version.dmg.sha256"
  "Remote-Mic-$version.en.txt"
  "Remote-Mic-$version.zh.txt"
  "Remote-Mic-$version.zip"
  "appcast-intel.xml"
  "appcast.xml"
)

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

for name in "${payload_names[@]}"; do
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
done

echo "PREVIEW CDN PATHS AVAILABLE: $TAG"
