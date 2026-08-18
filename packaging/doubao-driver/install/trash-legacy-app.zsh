move_legacy_app_to_trash_if_owned() {
  local legacy_path="$1"
  local legacy_plist="$2"
  local legacy_label="$3"
  local trash_root="$4"
  local trash_uid="$5"
  local migration_token="${6:-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$}"
  local trash_created=0
  local counter=0
  local trash_destination

  if [[ ! -e "$legacy_path" && ! -L "$legacy_path" ]]; then
    return
  fi
  if [[ "$legacy_plist" != "$legacy_path/Contents/Info.plist" ]] || \
     [[ "${legacy_path:h:t}" != "Applications" ]] || \
     [[ "${legacy_path:t}" != "Remote Mic.app" && "${legacy_path:t}" != "无线麦.app" ]]; then
    installer_message \
      "旧应用路径未通过安全检查，安装器已保留 $legacy_label。" \
      "The legacy app path failed the safety check, so $legacy_label was left untouched." >&2
    return
  fi
  if [[ ! -f "$legacy_plist" ]] || \
     [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$legacy_plist" 2>/dev/null || true)" != "com.hd838a.RemoteMic" ]]; then
    installer_message \
      "旧路径中的 $legacy_label 不属于无线麦SayAll.app，安装器已保留它不作处理。" \
      "The legacy $legacy_label path does not belong to SayAll and was left untouched."
    return
  fi
  if [[ "$trash_root" != /* || "$trash_root" == "/" || "$trash_uid" != <-> || \
        -z "$migration_token" || "$migration_token" == *[^A-Za-z0-9._-]* ]]; then
    installer_message \
      "无线麦SayAll.app 已安装，但废纸篓路径无效；旧版 $legacy_label 已保留在原位置。" \
      "SayAll was installed, but the Trash path was invalid. The legacy $legacy_label was left in place." >&2
    return
  fi

  if [[ ! -d "$trash_root" ]]; then
    if ! /bin/mkdir -p -- "$trash_root"; then
      installer_message \
        "无线麦SayAll.app 已安装，但无法使用废纸篓；旧版 $legacy_label 已保留在原位置。" \
        "SayAll was installed, but Trash was unavailable. The legacy $legacy_label was left in place." >&2
      return
    fi
    trash_created=1
  fi
  if [[ "$trash_created" -eq 1 ]]; then
    if ! /usr/sbin/chown "$trash_uid" "$trash_root" || \
       ! /bin/chmod 700 "$trash_root"; then
      installer_message \
        "无线麦SayAll.app 已安装，但无法安全准备废纸篓；旧版 $legacy_label 已保留在原位置。" \
        "SayAll was installed, but Trash could not be prepared safely. The legacy $legacy_label was left in place." >&2
      return
    fi
  fi

  trash_destination="$trash_root/${legacy_label%.app} (migrated $migration_token).app"
  while [[ -e "$trash_destination" || -L "$trash_destination" ]]; do
    counter=$((counter + 1))
    trash_destination="$trash_root/${legacy_label%.app} (migrated $migration_token-$counter).app"
  done

  /usr/bin/pkill -x RemoteMic 2>/dev/null || true
  if /bin/mv -n -- "$legacy_path" "$trash_destination" && \
     [[ ! -e "$legacy_path" && ! -L "$legacy_path" ]] && \
     [[ -e "$trash_destination" || -L "$trash_destination" ]]; then
    installer_message \
      "已将旧版 $legacy_label 移到废纸篓，可在需要时恢复。" \
      "Moved the legacy $legacy_label to Trash, where it can be restored if needed."
  else
    installer_message \
      "无线麦SayAll.app 已安装，但旧版 $legacy_label 无法移到废纸篓，已保留在原位置。" \
      "SayAll was installed, but the legacy $legacy_label could not be moved to Trash and was left in place." >&2
  fi
}
