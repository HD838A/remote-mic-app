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

driver_naming_variant() {
  local driver="$1" variant binary="$1/Contents/MacOS/MiRemoteV2ch"
  driver_naming_identity "$driver" || return 1
  [[ -x "$binary" && ! -L "$driver/Contents/MacOS" && ! -L "$binary" ]] || return 1
  /usr/bin/codesign --verify --deep --strict "$driver" >/dev/null 2>&1 || return 1
  /usr/bin/grep -aFq 'MiRemoteV%ich_UID' "$binary" || return 1
  variant="$(/usr/bin/plutil -extract SayAllNamingVariant raw -o - "$driver/Contents/Info.plist" 2>/dev/null || true)"
  case "$variant" in
    brand)
      /usr/bin/grep -aEq 'SayAll[[:cntrl:]]' "$binary" || return 1
      print brand ;;
    legacy|'')
      # Require the complete name constant. The hidden mirror contains
      # "MiRemoteV %ich 2" in both variants and must not identify legacy.
      /usr/bin/grep -aEq 'MiRemoteV %ich[[:cntrl:]]' "$binary" || return 1
      print legacy ;;
    *) return 1 ;;
  esac
}

# unknown can be repaired only with a trusted, previously committed record.
# An actual recognized driver always wins over historical App/receipt evidence.
resolve_driver_naming() {
  local installed="$1" recorded="$2" history_evidence="$3"
  case "$installed" in brand|legacy|none|unknown) ;; *) return 1 ;; esac
  case "$recorded" in brand|legacy|none) ;; *) return 1 ;; esac
  case "$history_evidence" in yes|no) ;; *) return 1 ;; esac
  case "$installed" in
    brand|legacy)
      [[ "$recorded" == none || "$recorded" == "$installed" ]] || return 1
      print -r -- "$installed" ;;
    unknown)
      [[ "$recorded" == brand || "$recorded" == legacy ]] || return 1
      print -r -- "$recorded" ;;
    none)
      case "$recorded" in
        brand|legacy) print -r -- "$recorded" ;;
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
      [[ "$(<"$marker")" == "SayAllDriverNaming:1:$variant" && "$recorded" == none ]] || return 1
      recorded="$variant"
    fi
  done
  print -r -- "$recorded"
}

commit_driver_naming_record() {
  local variant="$1" recorded
  recorded="$(driver_naming_record)" || return 1
  [[ "$recorded" == "$variant" ]] && return 0
  [[ "$recorded" == none && ( "$variant" == brand || "$variant" == legacy ) ]] || return 1
  # Immutable marker: a retry reuses it; no prior state is overwritten/deleted.
  (umask 077; set -o noclobber; print -r -- "SayAllDriverNaming:1:$variant" > "$NAMING_DIRECTORY/$variant")
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
