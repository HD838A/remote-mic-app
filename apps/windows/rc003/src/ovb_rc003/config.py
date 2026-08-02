"""Windows RC003 客户端的版本化配置。"""

from __future__ import annotations

import json
import os
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any, Mapping

from . import key_mapping

CONFIG_VERSION = 1
DEFAULT_CONFIG = {
    "version": CONFIG_VERSION,
    "output_endpoint_name": "",
    "output_endpoint_host_api": "",
    "gain_db": 10.0,
    "retry_delay": 2.0,
    "max_retry_delay": 30.0,
    "custom_mapping_enabled": True,
    "button_bindings": key_mapping.default_button_bindings(),
}


class ConfigError(ValueError):
    """配置缺失、损坏或超出支持范围。"""


def config_root() -> Path:
    override = os.environ.get("REMOTE_MIC_RC003_CONFIG_ROOT")
    if override:
        return Path(override).expanduser()
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return Path(local_app_data) / "RemoteMic" / "RC003"
    return Path.home() / ".remote-mic" / "rc003"


def config_path() -> Path:
    return config_root() / "config.json"


def log_path() -> Path:
    return config_root() / "remote-mic-rc003.log"


def _validated(data: Mapping[str, Any]) -> dict[str, Any]:
    version = data.get("version", CONFIG_VERSION)
    if version != CONFIG_VERSION:
        raise ConfigError(f"不支持的配置版本：{version!r}")

    name = data.get("output_endpoint_name", "")
    host_api = data.get("output_endpoint_host_api", "")
    if not isinstance(name, str) or not isinstance(host_api, str):
        raise ConfigError("音频端点名称和 Host API 必须是字符串")

    try:
        gain_db = float(data.get("gain_db", DEFAULT_CONFIG["gain_db"]))
        retry_delay = float(data.get("retry_delay", DEFAULT_CONFIG["retry_delay"]))
        max_retry_delay = float(
            data.get("max_retry_delay", DEFAULT_CONFIG["max_retry_delay"])
        )
    except (TypeError, ValueError) as exc:
        raise ConfigError("增益和重连时间必须是数字") from exc

    if not -24.0 <= gain_db <= 24.0:
        raise ConfigError("增益必须在 -24 dB 到 24 dB 之间")
    if retry_delay < 0.1 or max_retry_delay < retry_delay:
        raise ConfigError("重连时间配置无效")

    custom_mapping_enabled = data.get("custom_mapping_enabled", True)
    if not isinstance(custom_mapping_enabled, bool):
        raise ConfigError("按键映射开关必须是布尔值")

    button_bindings = _validated_button_bindings(data.get("button_bindings", {}))

    return {
        "version": CONFIG_VERSION,
        "output_endpoint_name": name.strip(),
        "output_endpoint_host_api": host_api.strip(),
        "gain_db": gain_db,
        "retry_delay": retry_delay,
        "max_retry_delay": max_retry_delay,
        "custom_mapping_enabled": custom_mapping_enabled,
        "button_bindings": button_bindings,
    }


def _validated_button_bindings(raw: object) -> dict[str, dict[str, str]]:
    defaults = key_mapping.default_button_bindings()
    if not isinstance(raw, Mapping):
        raw = {}
    for button_id in key_mapping.BUTTON_IDS:
        raw_gestures = raw.get(button_id, {})
        if not isinstance(raw_gestures, Mapping):
            continue
        for trigger in key_mapping.TRIGGERS:
            candidate = raw_gestures.get(trigger)
            if key_mapping.is_valid_action(candidate):
                defaults[button_id][trigger] = str(candidate)

    # 麦克风键永远由 ATVV 语音生命周期接管，不能被配置文件改写。
    defaults["mic"] = {
        key_mapping.SINGLE_CLICK: "voice",
        key_mapping.DOUBLE_CLICK: "disabled",
        key_mapping.LONG_PRESS: "disabled",
    }
    return defaults


def load_config(path: Path | None = None) -> dict[str, Any]:
    target = path or config_path()
    if not target.exists():
        return deepcopy(DEFAULT_CONFIG)
    try:
        raw = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError("配置文件无法读取或不是有效 JSON") from exc
    if not isinstance(raw, dict):
        raise ConfigError("配置文件根节点必须是对象")
    merged = deepcopy(DEFAULT_CONFIG)
    merged.update(raw)
    return _validated(merged)


def save_config(data: Mapping[str, Any], path: Path | None = None) -> dict[str, Any]:
    target = path or config_path()
    validated = _validated(data)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="config.", suffix=".tmp", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(validated, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return validated
