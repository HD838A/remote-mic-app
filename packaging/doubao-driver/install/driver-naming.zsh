# Shared by preinstall and postinstall. No user preference is written here.
# All values written to installer diagnostics are fixed enums.
driver_naming_failure() {
  print -u2 'DRIVER_NAMING phase=blocked result=failed reason='"$1"
  installer_message \
    "安装已停止：无法安全确定麦克风名称。现有驱动和设置已保留。请联系支持。" \
    "Installation stopped: the microphone name could not be determined safely. Existing drivers and settings were kept. Contact support." >&2
  return 2
}

driver_naming_identity() {
  local driver="$1" plist="$1/Contents/Info.plist"
  [[ ! -L "$driver" && ! -L "$driver/Contents" && ! -L "$plist" && -f "$plist" ]] &&
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)" == "com.hd838a.MiRemoteV2ch" ]] &&
    [[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist" 2>/dev/null)" == "MiRemoteV2ch" ]]
}

# Existing product files can retain their name despite damaged permissions or
# signatures. This observes naming only; it never approves a payload for loading.
driver_naming_observed_variant() {
  local driver="$1" binary="$1/Contents/MacOS/MiRemoteV2ch"
  driver_naming_identity "$driver" || return 1
  [[ -f "$binary" && ! -L "$driver/Contents/MacOS" && ! -L "$binary" ]] || return 1
  LC_ALL=C /usr/bin/grep -aFq 'MiRemoteV%ich_UID' "$binary" || return 1
  # The hidden mirror "MiRemoteV %ich 2" exists in both variants; require the
  # complete main name constant. Missing/damaged metadata must not rename it.
  if LC_ALL=C /usr/bin/grep -aEq 'SayAll[[:cntrl:]]' "$binary"; then
    ! LC_ALL=C /usr/bin/grep -aEq 'MiRemoteV %ich[[:cntrl:]]' "$binary" || return 1
    print brand
  elif LC_ALL=C /usr/bin/grep -aEq 'MiRemoteV %ich[[:cntrl:]]' "$binary"; then
    print legacy
  else
    return 1
  fi
}

# Payload and healthy-driver validation must retain executable/signature checks.
driver_naming_variant() {
  local driver="$1" observed marker
  [[ -x "$driver/Contents/MacOS/MiRemoteV2ch" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$driver" >/dev/null 2>&1 || return 1
  observed="$(driver_naming_observed_variant "$driver")" || return 1
  marker="$(/usr/bin/plutil -extract SayAllNamingVariant raw -o - "$driver/Contents/Info.plist" 2>/dev/null || true)"
  case "$observed:$marker" in brand:brand|legacy:legacy|legacy:) print -r -- "$observed" ;; *) return 1 ;; esac
}

# The installed product name wins over stale records. An unreadable product
# driver can be repaired from its committed record or legacy installation history.
resolve_driver_naming() {
  local installed="$1" recorded="$2" history_evidence="$3"
  case "$installed" in brand|legacy|none|unknown) ;; *) return 1 ;; esac
  case "$recorded" in brand|legacy|none|conflict) ;; *) return 1 ;; esac
  case "$history_evidence" in yes|no) ;; *) return 1 ;; esac
  case "$installed" in
    brand|legacy)
      print -r -- "$installed" ;;
    unknown)
      case "$recorded" in
        brand|legacy) print -r -- "$recorded" ;;
        none) [[ "$history_evidence" == yes ]] || return 1; print legacy ;;
        conflict) print legacy ;;
        *) return 1 ;;
      esac ;;
    none)
      case "$recorded" in
        brand|legacy) print -r -- "$recorded" ;;
        conflict) print legacy ;;
        none)
          case "$history_evidence" in
            yes) print legacy ;;
            no) print brand ;;
            *) return 1 ;;
          esac ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Reject symlinks and user-writable parents before root writes any state.
driver_naming_safe_directory() {
  local directory="$1" owner mode
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  owner="$(/usr/bin/stat -f %u "$directory")"
  mode="$(/usr/bin/stat -f %Lp "$directory")"
  [[ "$owner" == 0 ]] && (( (8#$mode & 8#022) == 0 ))
}

prepare_driver_naming_directory() {
  local volume="$1" directory
  NAMING_VOLUME="$volume"
  NAMING_DIRECTORY="${volume%/}/Library/Application Support/RemoteMic/DriverNaming"
  for directory in "${volume%/}/Library" "${volume%/}/Library/Application Support"; do
    driver_naming_safe_directory "$directory" || return 1
  done
  for directory in "${NAMING_DIRECTORY:h}" "$NAMING_DIRECTORY"; do
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
      /bin/mkdir -m 755 -- "$directory" || return 1
    fi
    driver_naming_safe_directory "$directory" || return 1
  done
}

driver_naming_record() {
  local variant marker recorded=none mode entry
  for entry in "$NAMING_DIRECTORY"/*(DN); do
    [[ "${entry:t}" == brand || "${entry:t}" == legacy ]] || return 1
  done
  for variant in brand legacy; do
    marker="$NAMING_DIRECTORY/$variant"
    if [[ -e "$marker" || -L "$marker" ]]; then
      [[ -f "$marker" && ! -L "$marker" && "$(/usr/bin/stat -f %u "$marker")" == 0 ]] || return 1
      mode="$(/usr/bin/stat -f %Lp "$marker")"
      (( (8#$mode & 8#022) == 0 )) || return 1
      [[ "$(<"$marker")" == "SayAllDriverNaming:1:$variant" ]] || return 1
      if [[ "$recorded" == none ]]; then recorded="$variant"; else recorded=conflict; fi
    fi
  done
  print -r -- "$recorded"
}

commit_driver_naming_record() {
  local variant="$1" recorded directory trash_root token counter=0 marker backup
  local -a previous_markers backups
  case "$variant" in brand|legacy) ;; *) return 1 ;; esac
  recorded="$(driver_naming_record)" || return 1
  [[ "$recorded" == "$variant" ]] && return 0
  if [[ "$recorded" != none ]]; then
    # Preserve stale, validated records in root's Trash before reconciliation.
    # The actual driver is unchanged; a failed write restores all old records.
    trash_root="${NAMING_VOLUME%/}/private/var/root/.Trash"
    for directory in "${NAMING_VOLUME%/}/private" "${NAMING_VOLUME%/}/private/var" \
      "${NAMING_VOLUME%/}/private/var/root" "$trash_root"; do
      if [[ ! -e "$directory" && ! -L "$directory" ]]; then
        /bin/mkdir -m 700 -- "$directory" || return 1
      fi
      driver_naming_safe_directory "$directory" || return 1
    done
    token="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
    for marker in "$NAMING_DIRECTORY"/{brand,legacy}; do
      [[ -f "$marker" ]] || continue
      backup="$trash_root/SayAllDriverNaming-${marker:t}-$token-$counter"
      while [[ -e "$backup" || -L "$backup" ]]; do
        counter=$((counter + 1))
        backup="$trash_root/SayAllDriverNaming-${marker:t}-$token-$counter"
      done
      if ! /bin/mv -n -- "$marker" "$backup" || [[ -e "$marker" || ! -f "$backup" ]]; then
        for (( counter=1; counter<=${#backups}; counter++ )); do
          /bin/mv -n -- "$backups[$counter]" "$previous_markers[$counter]" || return 1
        done
        return 1
      fi
      previous_markers+=("$marker")
      backups+=("$backup")
    done
  fi
  if (umask 077; set -o noclobber; print -r -- "SayAllDriverNaming:1:$variant" > "$NAMING_DIRECTORY/$variant"); then
    if [[ "$recorded" != none ]]; then
      print -u2 "DRIVER_NAMING phase=reconciled result=verified previous=$recorded variant=$variant backup=trash"
    fi
    return 0
  fi
  if (( ${#backups} > 0 )) && [[ -e "$NAMING_DIRECTORY/$variant" ]]; then
    # A failed write may leave a partial marker. Keep it recoverable so it
    # cannot obstruct restoring the original record or the next retry.
    backup="$trash_root/SayAllDriverNaming-failed-$token-$counter"
    while [[ -e "$backup" || -L "$backup" ]]; do
      counter=$((counter + 1))
      backup="$trash_root/SayAllDriverNaming-failed-$token-$counter"
    done
    /bin/mv -n -- "$NAMING_DIRECTORY/$variant" "$backup" || return 1
    [[ ! -e "$NAMING_DIRECTORY/$variant" ]] || return 1
  fi
  for (( counter=1; counter<=${#backups}; counter++ )); do
    /bin/mv -n -- "$backups[$counter]" "$previous_markers[$counter]" || return 1
  done
  return 1
}

check_driver_naming_duplicates() {
  local volume="$1" canonical="$2" hal driver identifier
  for hal in "${volume%/}/Library/Audio/Plug-Ins/HAL" "${volume%/}/System/Library/Audio/Plug-Ins/HAL"; do
    local parent="$hal"
    while [[ "$parent" != "${volume%/}" && "$parent" != / ]]; do
      [[ ! -L "$parent" ]] || return 1
      if [[ -e "$parent" ]]; then driver_naming_safe_directory "$parent" || return 1; fi
      parent="${parent:h}"
    done
    for driver in "$hal"/*.driver(N); do
      [[ "$driver" == "$canonical" ]] && continue
      # Only standard, public plug-in registration metadata is inspected.
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$driver/Contents/Info.plist" 2>/dev/null || true)"
      [[ "$identifier" != "com.hd838a.MiRemoteV2ch" ]] || return 1
    done
  done
}

has_driver_naming_history() {
  local volume="$1" preference
  [[ "$OWNED_APP_FOUND" -eq 0 ]] || return 0
  /usr/sbin/pkgutil --volume "$volume" --pkg-info com.hd838a.RemoteMic.installer >/dev/null 2>&1 && return 0
  /usr/sbin/pkgutil --volume "$volume" --pkg-info com.hd838a.MiRemoteV2ch >/dev/null 2>&1 && return 0
  # Read only this product's settings. Never inspect another App's files.
  for preference in "${volume%/}"/Users/*/Library/Preferences/com.hd838a.RemoteMic.plist(N); do
    /usr/bin/defaults read "${preference%.plist}" selectedAudioDeviceUID >/dev/null 2>&1 && return 0
  done
  return 1
}
