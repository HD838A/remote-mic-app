# Shared by install and uninstall scripts. No user preference is written here.
# All values written to installer diagnostics are fixed enums.
DRIVER_NAMING_PRODUCT_BUNDLE_ID="com.hd838a.MiRemoteV2ch"

# Fixed diagnostic state for the HAL safety scan. Never store paths, bundle
# names or third-party identities here: installer logs only carry enums.
DRIVER_NAMING_SCAN_REASON=""
DRIVER_NAMING_SCAN_DETAIL=""
DRIVER_NAMING_SCAN_SCOPE=""
DRIVER_NAMING_SCAN_LEVEL=""
DRIVER_NAMING_SCAN_ISSUE=""
DRIVER_NAMING_SCAN_EXTRAS=0
DRIVER_NAMING_SCAN_RECONCILED=0

driver_naming_failure() {
  local reason="$1" detail="${DRIVER_NAMING_SCAN_DETAIL:-}" fields=""
  case "$reason" in
    duplicate_driver|unsafe_hal_entry|unsafe_hal_parent)
      fields=" scope=${DRIVER_NAMING_SCAN_SCOPE:-unknown}"
      [[ -z "$detail" ]] || fields="$fields detail=$detail"
      [[ -z "${DRIVER_NAMING_SCAN_LEVEL:-}" ]] || fields="$fields level=$DRIVER_NAMING_SCAN_LEVEL"
      [[ -z "${DRIVER_NAMING_SCAN_ISSUE:-}" ]] || fields="$fields issue=$DRIVER_NAMING_SCAN_ISSUE"
      if (( DRIVER_NAMING_SCAN_EXTRAS != 0 )); then
        fields="$fields count=$DRIVER_NAMING_SCAN_EXTRAS"
      fi
      ;;
  esac
  print -u2 'DRIVER_NAMING phase=blocked result=failed reason='"$reason$fields"
  driver_naming_refusal_message "$detail"
  return 2
}

# Explain a stopped installation without exposing paths or foreign identities.
# The writable-scope duplicate case is reconciled automatically; the remaining
# messages describe only states the installer will not modify on its own.
driver_naming_refusal_message() {
  local detail="$1"
  case "$detail" in
    duplicate_bundle)
      if [[ "${DRIVER_NAMING_SCAN_SCOPE:-}" == system ]]; then
        installer_message \
          "安装已停止：系统只读驱动目录中仍有一份无线麦 SayAll 兼容麦克风。安装器不能修改该目录，现有驱动和设置已保留。请把安装器日志发送给支持。" \
          "Installation stopped: a second SayAll-compatible microphone remains in a read-only system driver directory. The installer cannot modify that directory; existing drivers and settings were kept. Send the installer log to support." >&2
      else
        installer_message \
          "安装已停止：另一份无线麦 SayAll 兼容麦克风驱动无法安全移入废纸篓。现有驱动和设置已保留。请把安装器日志发送给支持。" \
          "Installation stopped: a second SayAll-compatible microphone driver could not be moved to Trash safely. Existing drivers and settings were kept. Send the installer log to support." >&2
      fi ;;
    symlink_bundle)
      installer_message \
        "安装已停止：音频驱动目录中存在指向无线麦 SayAll 兼容麦克风的符号链接，安装器不会跟随或删除链接。现有驱动和设置已保留。" \
        "Installation stopped: a symbolic link in the audio driver directory resolves to the SayAll-compatible microphone. The installer does not follow or remove links; existing drivers and settings were kept." >&2 ;;
    unverified_duplicate)
      installer_message \
        "安装已停止：另一份同名驱动无法确认属于无线麦 SayAll，安装器未做任何修改。" \
        "Installation stopped: another driver with the product name could not be verified as SayAll's own; nothing was changed." >&2 ;;
    reconcile_failed)
      installer_message \
        "安装已停止：无法把多余的无线麦 SayAll 兼容麦克风驱动安全移入废纸篓，安装器未做进一步修改。请把安装器日志发送给支持。" \
        "Installation stopped: the extra SayAll-compatible microphone driver could not be moved to Trash safely; nothing else was changed. Send the installer log to support." >&2 ;;
    unsafe_hal_parent)
      installer_message \
        "安装已停止：系统音频驱动目录的所有权、权限或链接状态异常，安装器未做任何修改。请把安装器日志发送给支持。" \
        "Installation stopped: the ownership, permissions or link state of the system audio driver directory is unsafe; nothing was changed. Send the installer log to support." >&2 ;;
    *)
      installer_message \
        "安装已停止：无法安全确定麦克风名称。现有驱动和设置已保留。请联系支持。" \
        "Installation stopped: the microphone name could not be determined safely. Existing drivers and settings were kept. Contact support." >&2 ;;
  esac
}

# Classify one directory on the path to a HAL plug-in folder. Fixed enums only.
driver_naming_directory_issue() {
  local directory="$1" owner mode
  if [[ -L "$directory" ]]; then
    print symlink
    return 0
  fi
  if [[ ! -e "$directory" ]]; then
    print missing
    return 0
  fi
  if [[ ! -d "$directory" ]]; then
    print not_directory
    return 0
  fi
  owner="$(/usr/bin/stat -f %u "$directory" 2>/dev/null)" || { print unreadable; return 0; }
  [[ "$owner" == 0 ]] || { print not_root; return 0; }
  mode="$(/usr/bin/stat -f %Lp "$directory" 2>/dev/null)" || { print unreadable; return 0; }
  if (( (8#$mode & 8#022) != 0 )); then
    if (( (8#$mode & 8#002) != 0 )); then
      print other_writable
    else
      print group_writable
    fi
    return 0
  fi
  print safe
  return 0
}

driver_naming_path_level() {
  local volume="$1" directory="$2" relative
  relative="${directory#${volume%/}}"
  case "$relative" in
    /Library) print library ;;
    /Library/Audio) print audio ;;
    /Library/Audio/Plug-Ins) print plugins ;;
    /Library/Audio/Plug-Ins/HAL) print hal ;;
    /System) print system ;;
    /System/Library) print system_library ;;
    /System/Library/Audio) print system_audio ;;
    /System/Library/Audio/Plug-Ins) print system_plugins ;;
    /System/Library/Audio/Plug-Ins/HAL) print system_hal ;;
    *) print unknown ;;
  esac
}

driver_naming_identity() {
  local driver="$1" plist="$1/Contents/Info.plist"
  [[ ! -L "$driver" && ! -L "$driver/Contents" && ! -L "$plist" && -f "$plist" ]] &&
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)" == "$DRIVER_NAMING_PRODUCT_BUNDLE_ID" ]] &&
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
      # Older uninstallers leave records, receipts and preferences behind.
      # With no product driver to preserve, install the current SayAll name.
      print brand ;;
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

# Root Trash on the target volume. Every level must stay root-owned and not
# writable by other users, matching the existing naming-record reconciliation.
driver_naming_trash_root() {
  local volume="$1" trash_root directory
  trash_root="${volume%/}/private/var/root/.Trash"
  for directory in "${volume%/}/private" "${volume%/}/private/var" \
    "${volume%/}/private/var/root" "$trash_root"; do
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
      /bin/mkdir -m 700 -- "$directory" || return 1
    fi
    driver_naming_safe_directory "$directory" || return 1
  done
  print -r -- "$trash_root"
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
  local variant="$1" recorded trash_root token counter=0 marker backup
  local -a previous_markers backups
  case "$variant" in brand|legacy) ;; *) return 1 ;; esac
  recorded="$(driver_naming_record)" || return 1
  [[ "$recorded" == "$variant" ]] && return 0
  if [[ "$recorded" != none ]]; then
    # Preserve stale, validated records in root's Trash before reconciliation.
    # The actual driver is unchanged; a failed write restores all old records.
    trash_root="$(driver_naming_trash_root "$NAMING_VOLUME")" || return 1
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

# Verify that the product microphone driver is unique and that every directory
# leading to a HAL plug-in folder is root-owned, not writable by other users and
# free of symlinks. A duplicate bundle that is verifiably this product and lives
# in the writable HAL scope is moved into root's Trash (recoverable) when
# requested; every other state still stops the installation. Diagnostics only
# carry fixed enums: no paths, bundle names or third-party identities.
check_driver_naming_duplicates() {
  local volume="$1" canonical="$2" reconcile="${3:-check}" marker="${4:-}"
  local scope hal parent issue driver identifier
  local drivers symlinked unreadable external
  local library_extras=0 system_extras=0 symlink_extras=0
  local symlink_scope="" trash_root token counter=0 backup
  local -a library_paths system_paths moved_sources moved_targets
  DRIVER_NAMING_SCAN_REASON=""
  DRIVER_NAMING_SCAN_DETAIL=""
  DRIVER_NAMING_SCAN_SCOPE=""
  DRIVER_NAMING_SCAN_LEVEL=""
  DRIVER_NAMING_SCAN_ISSUE=""
  DRIVER_NAMING_SCAN_EXTRAS=0
  DRIVER_NAMING_SCAN_RECONCILED=0

  # Validate the whole path chain before inspecting or moving anything.
  for scope in library system; do
    if [[ "$scope" == library ]]; then
      hal="${volume%/}/Library/Audio/Plug-Ins/HAL"
    else
      hal="${volume%/}/System/Library/Audio/Plug-Ins/HAL"
    fi
    parent="$hal"
    while [[ "$parent" != "${volume%/}" && "$parent" != / ]]; do
      issue=""
      if [[ -L "$parent" ]]; then
        issue="$(driver_naming_directory_issue "$parent")"
      elif [[ -e "$parent" ]] && ! driver_naming_safe_directory "$parent"; then
        issue="$(driver_naming_directory_issue "$parent")"
      fi
      if [[ -n "$issue" ]]; then
        DRIVER_NAMING_SCAN_REASON=unsafe_hal_parent
        DRIVER_NAMING_SCAN_DETAIL=unsafe_hal_parent
        DRIVER_NAMING_SCAN_SCOPE="$scope"
        DRIVER_NAMING_SCAN_LEVEL="$(driver_naming_path_level "$volume" "$parent")"
        DRIVER_NAMING_SCAN_ISSUE="$issue"
        return 1
      fi
      parent="${parent:h}"
    done
  done

  for scope in library system; do
    if [[ "$scope" == library ]]; then
      hal="${volume%/}/Library/Audio/Plug-Ins/HAL"
    else
      hal="${volume%/}/System/Library/Audio/Plug-Ins/HAL"
    fi
    drivers=0
    symlinked=0
    unreadable=0
    external=0
    for driver in "$hal"/*.driver(N); do
      drivers=$((drivers + 1))
      if [[ "$driver" == "$canonical" ]]; then
        continue
      fi
      # Case-insensitive volumes may report another spelling of the same
      # on-disk bundle. Compare directory identity, never by following links.
      if [[ ! -L "$driver" && -e "$canonical" && "$driver" -ef "$canonical" ]]; then
        continue
      fi
      if [[ -L "$driver" ]]; then
        symlinked=$((symlinked + 1))
      fi
      # Only standard, public plug-in registration metadata is inspected.
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$driver/Contents/Info.plist" 2>/dev/null || true)"
      if [[ -z "$identifier" ]]; then
        unreadable=$((unreadable + 1))
        continue
      fi
      [[ "$identifier" == "$DRIVER_NAMING_PRODUCT_BUNDLE_ID" ]] || continue
      external=$((external + 1))
      if [[ -L "$driver" ]]; then
        symlink_extras=$((symlink_extras + 1))
        [[ -n "$symlink_scope" ]] || symlink_scope="$scope"
      fi
      if [[ "$scope" == library ]]; then
        library_paths+=("$driver")
      else
        system_paths+=("$driver")
      fi
    done
    print -u2 "DRIVER_NAMING phase=hal_scan scope=$scope drivers=$drivers ours_external=$external symlinked=$symlinked unreadable=$unreadable"
  done

  if (( symlink_extras > 0 )); then
    DRIVER_NAMING_SCAN_REASON=unsafe_hal_entry
    DRIVER_NAMING_SCAN_DETAIL=symlink_bundle
    DRIVER_NAMING_SCAN_SCOPE="$symlink_scope"
    DRIVER_NAMING_SCAN_ISSUE=symlink
    DRIVER_NAMING_SCAN_EXTRAS=$symlink_extras
    return 1
  fi

  library_extras=${#library_paths}
  system_extras=${#system_paths}
  if (( system_extras > 0 )); then
    DRIVER_NAMING_SCAN_REASON=duplicate_driver
    DRIVER_NAMING_SCAN_DETAIL=duplicate_bundle
    DRIVER_NAMING_SCAN_SCOPE=system
    DRIVER_NAMING_SCAN_ISSUE=read_only_scope
    DRIVER_NAMING_SCAN_EXTRAS=$system_extras
    return 1
  fi
  if (( library_extras == 0 )); then
    return 0
  fi

  DRIVER_NAMING_SCAN_REASON=duplicate_driver
  DRIVER_NAMING_SCAN_DETAIL=duplicate_bundle
  DRIVER_NAMING_SCAN_SCOPE=library
  DRIVER_NAMING_SCAN_EXTRAS=$library_extras
  if [[ "$reconcile" != reconcile ]]; then
    DRIVER_NAMING_SCAN_ISSUE=not_reconciled
    return 1
  fi
  for driver in "${library_paths[@]}"; do
    if ! driver_naming_identity "$driver"; then
      DRIVER_NAMING_SCAN_DETAIL=unverified_duplicate
      DRIVER_NAMING_SCAN_ISSUE=identity_mismatch
      return 1
    fi
  done
  trash_root="$(driver_naming_trash_root "$volume")" || {
    DRIVER_NAMING_SCAN_DETAIL=reconcile_failed
    DRIVER_NAMING_SCAN_ISSUE=trash_unavailable
    return 1
  }
  token="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
  for driver in "${library_paths[@]}"; do
    counter=0
    backup="$trash_root/MiRemoteV2ch (duplicate $token).driver"
    while [[ -e "$backup" || -L "$backup" ]]; do
      counter=$((counter + 1))
      backup="$trash_root/MiRemoteV2ch (duplicate $token-$counter).driver"
    done
    if ! /bin/mv -n -- "$driver" "$backup" || [[ -e "$driver" || -L "$driver" || ! -d "$backup" ]]; then
      DRIVER_NAMING_SCAN_DETAIL=reconcile_failed
      DRIVER_NAMING_SCAN_ISSUE=move_failed
      driver_naming_restore_duplicates moved_sources moved_targets || return 1
      return 1
    fi
    moved_sources+=("$driver")
    moved_targets+=("$backup")
  done
  # Preserve the decision for postinstall: removing a loaded plug-in requires a
  # Core Audio restart even when the canonical driver itself is already healthy.
  if [[ -n "$marker" ]]; then
    if [[ -L "$marker" ]] || ! (umask 077; print -r -- "SayAllDriverNamingDuplicates:1" > "$marker"); then
      DRIVER_NAMING_SCAN_DETAIL=reconcile_failed
      DRIVER_NAMING_SCAN_ISSUE=marker_failed
      driver_naming_restore_duplicates moved_sources moved_targets || return 1
      return 1
    fi
  fi
  DRIVER_NAMING_SCAN_RECONCILED=$library_extras
  print -u2 "DRIVER_NAMING phase=reconciled result=verified scope=library count=$library_extras backup=trash"
  return 0
}

# Restore already moved duplicates when reconciliation cannot complete.
driver_naming_restore_duplicates() {
  local sources_name="$1" targets_name="$2" index source target
  local -a sources targets
  sources=("${(@P)sources_name}")
  targets=("${(@P)targets_name}")
  index=${#sources}
  while (( index > 0 )); do
    source="${sources[$index]}"
    target="${targets[$index]}"
    if ! /bin/mv -n -- "$target" "$source" || [[ -e "$target" || ! -d "$source" ]]; then
      print -u2 "DRIVER_NAMING phase=reconciled result=failed reason=duplicate_driver rollback=unknown"
      return 1
    fi
    index=$((index - 1))
  done
  return 0
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
