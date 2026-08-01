"""Strict runtime loader for the shared ``device-profiles/*.json`` catalog.

The catalog is presentation metadata, not a driver registry. Existing RC003
and DJI runtime routing deliberately stays unchanged in Phase 0. If the
directory or any profile is invalid, the catalog becomes visibly unavailable;
there is no second hard-coded list of device names or support states.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Optional, Tuple

from . import audio_output, resources

RC003_ID = "xiaomi-rc003"
DJI_MIC_2_ID = "dji-mic-2"

_VALID_STATUSES = frozenset(("implemented", "research", "planned", "unsupported"))
_STATUS_ORDER = {"implemented": 0, "research": 1, "planned": 2, "unsupported": 3}
_VALID_TRANSPORT_KINDS = frozenset(
    (
        "ble-gatt",
        "bluetooth-hid",
        "bluetooth-br-edr-audio",
        "usb-digital-audio",
        "analog-audio",
        "system-audio-input",
    )
)
_VALID_TRANSPORT_ROLES = frozenset(
    ("control", "button-input", "voice-input", "voice-output")
)
_VALID_CAPABILITIES = frozenset(
    (
        "voice-capture",
        "press-to-talk",
        "button-input",
        "host-key-mapping",
        "gain-control",
        "channel-selection",
        "device-status",
    )
)
_VALID_PLATFORMS = frozenset(("windows",))
_ID_PATTERN = re.compile(r"^[a-z0-9]+([.-][a-z0-9]+)*$")


class DeviceCatalogLoadError(RuntimeError):
    """The complete catalog is unusable; callers must show an unavailable state."""


@dataclass(frozen=True)
class CatalogTransport:
    kind: str
    role: str
    status: str
    notes: str


@dataclass(frozen=True)
class CatalogPlatform:
    platform: str
    status: str
    notes: str


@dataclass(frozen=True)
class DeviceUiProfile:
    device_id: str
    display_name: str
    vendor: str
    model: str
    support_status: str
    support_notes: str
    description: str
    transports: Tuple[CatalogTransport, ...]
    capabilities: Tuple[str, ...]
    platforms: Tuple[CatalogPlatform, ...]
    bluetooth_names: Tuple[str, ...]
    bluetooth_name_prefixes: Tuple[str, ...]
    audio_input_name_prefixes: Tuple[str, ...]

    @property
    def has_editable_button_mapping(self) -> bool:
        return "host-key-mapping" in self.capabilities


@dataclass(frozen=True)
class DeviceControl:
    control_id: str
    display_name: str
    hardware_behavior: str
    windows_mapping: str


@dataclass(frozen=True)
class DeviceCatalog:
    profiles: Tuple[DeviceUiProfile, ...]
    source_directory: Path

    @property
    def by_id(self) -> Mapping[str, DeviceUiProfile]:
        return {profile.device_id: profile for profile in self.profiles}


DJI_MIC_2_CONTROLS: Tuple[DeviceControl, ...] = (
    DeviceControl(
        "record",
        "录音键",
        "单击控制发射器内录；长按 3 秒切换蓝牙连接模式。",
        "未确认 Windows 输入事件，不开放自定义映射。",
    ),
    DeviceControl(
        "link",
        "连接键",
        "长按 2 秒开始连接；部分手机支持单击遥控拍照或录像。",
        "DJI 未承诺 Windows HID 行为，当前不可映射。",
    ),
    DeviceControl(
        "power",
        "电源键",
        "长按 2 秒开关机；单击切换智能降噪。",
        "发射器本机功能，不属于 Windows 按键映射。",
    ),
)


def _mapping(value: object, context: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise DeviceCatalogLoadError(f"{context} must be an object")
    return value


def _list(value: object, context: str, *, allow_empty: bool = False) -> list:
    if not isinstance(value, list) or (not allow_empty and not value):
        suffix = "an array" if allow_empty else "a non-empty array"
        raise DeviceCatalogLoadError(f"{context} must be {suffix}")
    return value


def _text(mapping: Mapping[str, object], key: str, context: str) -> str:
    if key not in mapping:
        raise DeviceCatalogLoadError(f"{context} missing required field {key}")
    value = mapping[key]
    if not isinstance(value, str) or not value.strip():
        raise DeviceCatalogLoadError(f"{context}.{key} must be a non-empty string")
    return value.strip()


def _status(mapping: Mapping[str, object], context: str) -> str:
    value = _text(mapping, "status", context)
    if value not in _VALID_STATUSES:
        raise DeviceCatalogLoadError(f"{context}.status has unknown value {value!r}")
    return value


def _optional_string_tuple(mapping: Mapping[str, object], key: str, context: str) -> Tuple[str, ...]:
    if key not in mapping:
        return ()
    values = _list(mapping[key], f"{context}.{key}", allow_empty=True)
    result = []
    for index, value in enumerate(values):
        if not isinstance(value, str) or not value.strip():
            raise DeviceCatalogLoadError(
                f"{context}.{key}[{index}] must be a non-empty string"
            )
        result.append(value.strip())
    if len(result) != len(set(result)):
        raise DeviceCatalogLoadError(f"{context}.{key} contains duplicates")
    return tuple(result)


def _parse_profile(raw: object, filename: str) -> DeviceUiProfile:
    context = filename
    profile = _mapping(raw, context)
    required = (
        "schemaVersion",
        "id",
        "displayName",
        "vendor",
        "model",
        "support",
        "identity",
        "transports",
        "capabilities",
        "platforms",
        "sources",
    )
    missing = [key for key in required if key not in profile]
    if missing:
        raise DeviceCatalogLoadError(f"{context} missing required field {missing[0]}")
    if profile["schemaVersion"] != 1:
        raise DeviceCatalogLoadError(f"{context}.schemaVersion is not supported")

    device_id = _text(profile, "id", context)
    if not _ID_PATTERN.fullmatch(device_id):
        raise DeviceCatalogLoadError(f"{context}.id is invalid")
    display_name = _text(profile, "displayName", context)
    vendor = _text(profile, "vendor", context)
    model = _text(profile, "model", context)

    support = _mapping(profile["support"], f"{context}.support")
    support_status = _status(support, f"{context}.support")
    support_notes = _text(support, "notes", f"{context}.support")

    identity = _mapping(profile["identity"], f"{context}.identity")
    bluetooth_names = _optional_string_tuple(identity, "bluetoothNames", f"{context}.identity")
    bluetooth_name_prefixes = _optional_string_tuple(
        identity, "bluetoothNamePrefixes", f"{context}.identity"
    )
    audio_input_name_prefixes = _optional_string_tuple(
        identity, "audioInputNamePrefixes", f"{context}.identity"
    )

    transports = []
    for index, raw_transport in enumerate(
        _list(profile["transports"], f"{context}.transports")
    ):
        transport_context = f"{context}.transports[{index}]"
        transport = _mapping(raw_transport, transport_context)
        kind = _text(transport, "kind", transport_context)
        role = _text(transport, "role", transport_context)
        if kind not in _VALID_TRANSPORT_KINDS:
            raise DeviceCatalogLoadError(f"{transport_context}.kind is unknown")
        if role not in _VALID_TRANSPORT_ROLES:
            raise DeviceCatalogLoadError(f"{transport_context}.role is unknown")
        transports.append(
            CatalogTransport(
                kind=kind,
                role=role,
                status=_status(transport, transport_context),
                notes=_text(transport, "notes", transport_context),
            )
        )

    raw_capabilities = _list(profile["capabilities"], f"{context}.capabilities")
    capabilities = tuple(raw_capabilities)
    if any(not isinstance(value, str) or value not in _VALID_CAPABILITIES for value in capabilities):
        raise DeviceCatalogLoadError(f"{context}.capabilities contains an unknown value")
    if len(capabilities) != len(set(capabilities)):
        raise DeviceCatalogLoadError(f"{context}.capabilities contains duplicates")

    platforms = []
    seen_platforms = set()
    for index, raw_platform in enumerate(_list(profile["platforms"], f"{context}.platforms")):
        platform_context = f"{context}.platforms[{index}]"
        platform = _mapping(raw_platform, platform_context)
        platform_name = _text(platform, "platform", platform_context)
        if platform_name not in _VALID_PLATFORMS:
            raise DeviceCatalogLoadError(f"{platform_context}.platform is unknown")
        if platform_name in seen_platforms:
            raise DeviceCatalogLoadError(f"{context}.platforms contains duplicate {platform_name}")
        seen_platforms.add(platform_name)
        platforms.append(
            CatalogPlatform(
                platform=platform_name,
                status=_status(platform, platform_context),
                notes=_text(platform, "notes", platform_context),
            )
        )

    if "protocols" in profile:
        for index, raw_protocol in enumerate(
            _list(profile["protocols"], f"{context}.protocols", allow_empty=True)
        ):
            protocol_context = f"{context}.protocols[{index}]"
            protocol = _mapping(raw_protocol, protocol_context)
            _text(protocol, "id", protocol_context)
            _status(protocol, protocol_context)
            _text(protocol, "notes", protocol_context)

    sources = _list(profile["sources"], f"{context}.sources")
    if any(not isinstance(source, str) or not source.strip() for source in sources):
        raise DeviceCatalogLoadError(f"{context}.sources must contain non-empty strings")

    windows_platform = next(
        (entry for entry in platforms if entry.platform == "windows"), None
    )
    windows_notes = windows_platform.notes if windows_platform is not None else ""
    voice_input_only = (
        "host-key-mapping" not in capabilities
        and any(transport.role == "voice-input" for transport in transports)
    )
    prefix = "作为 Windows 录音输入使用；" if voice_input_only else ""
    description = " ".join(part for part in (prefix + support_notes, windows_notes) if part)

    return DeviceUiProfile(
        device_id=device_id,
        display_name=display_name,
        vendor=vendor,
        model=model,
        support_status=support_status,
        support_notes=support_notes,
        description=description,
        transports=tuple(transports),
        capabilities=capabilities,
        platforms=tuple(platforms),
        bluetooth_names=bluetooth_names,
        bluetooth_name_prefixes=bluetooth_name_prefixes,
        audio_input_name_prefixes=audio_input_name_prefixes,
    )


def load_device_catalog(directory: Optional[Path] = None) -> DeviceCatalog:
    if directory is None:
        directory = resources.find_device_profiles_directory()
    if directory is None:
        raise DeviceCatalogLoadError("device profile directory is unavailable")
    directory = Path(directory)
    if not directory.is_dir():
        raise DeviceCatalogLoadError("device profile directory is unavailable")

    paths = sorted(directory.glob("*.json"))
    if not paths:
        raise DeviceCatalogLoadError("device profile directory contains no JSON profiles")

    profiles = []
    seen_ids = set()
    for path in paths:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise DeviceCatalogLoadError(f"cannot read {path.name}: {type(exc).__name__}") from exc
        profile = _parse_profile(raw, path.name)
        if profile.device_id in seen_ids:
            raise DeviceCatalogLoadError(f"duplicate device profile id {profile.device_id}")
        seen_ids.add(profile.device_id)
        profiles.append(profile)

    profiles.sort(key=lambda profile: (_STATUS_ORDER[profile.support_status], profile.device_id))
    return DeviceCatalog(tuple(profiles), directory)


try:
    DEFAULT_CATALOG = load_device_catalog()
    CATALOG_ERROR: Optional[str] = None
except DeviceCatalogLoadError as exc:
    DEFAULT_CATALOG = None
    CATALOG_ERROR = str(exc)

DEVICE_PROFILES: Tuple[DeviceUiProfile, ...] = (
    DEFAULT_CATALOG.profiles if DEFAULT_CATALOG is not None else ()
)
DEVICE_PROFILE_BY_ID = {profile.device_id: profile for profile in DEVICE_PROFILES}


def normalize_device_id(value: object) -> str:
    """Preserves the pre-catalog runtime selection default.

    This does not make the catalog available or invent a display profile: the
    production RC003/DJI routing intentionally remains independent in Phase 0.
    """

    candidate = str(value or "").strip()
    return candidate if candidate in DEVICE_PROFILE_BY_ID else RC003_ID


def profile_for(device_id: object) -> DeviceUiProfile:
    normalized = normalize_device_id(device_id)
    try:
        return DEVICE_PROFILE_BY_ID[normalized]
    except KeyError as exc:
        raise DeviceCatalogLoadError(CATALOG_ERROR or "device profile is unavailable") from exc


def dji_mic_2_input_status(endpoints: Iterable[audio_output.AudioEndpoint]) -> str:
    """Privacy-safe status text based on real PortAudio recording endpoints."""

    if any(audio_output.is_dji_mic_2_input_endpoint(endpoint.name) for endpoint in endpoints):
        return "已检测到可用的 DJI Mic 2 录音输入。Windows 听写会使用系统当前选择的麦克风。"
    return (
        "未检测到可用的 DJI Mic 2 录音输入。仅显示已配对不代表可录音；"
        "请先给发射器开机并在 Windows 声音设置中确认输入端点。"
    )
