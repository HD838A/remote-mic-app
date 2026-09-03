"""User-selected audio output endpoint resolution, with a strict fail-closed
policy: voice never falls back to the system default device.

Enumeration and PCM playback (Windows-only, via the ``sounddevice`` package)
are separated from the selection logic below so the selection/fail-closed
contract is unit-testable on any OS without the real dependency installed.

This module never changes which device Windows considers "default" for
anything; it only ever writes PCM to the one endpoint the user explicitly
picked in the settings UI, by name, each time a voice session starts.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence


_HOST_API_PREFERENCE = {
    "windows wasapi": 0,
    "windows directsound": 1,
    "mme": 2,
    "windows wdm-ks": 3,
}
_WINDOWS_DEFAULT_OUTPUT_ALIASES = {
    "microsoft sound mapper - output",
    "primary sound driver",
}


class AudioOutputUnavailableError(Exception):
    """Raised whenever voice cannot be routed. Callers must fail the voice
    path closed on this (buttons keep working; only voice is affected).
    """


@dataclass(frozen=True)
class AudioEndpoint:
    name: str
    host_api: str = ""


def preferred_output_endpoints(
    endpoints: Sequence[AudioEndpoint],
) -> List[AudioEndpoint]:
    """Return one user-facing choice per Windows playback device.

    PortAudio exposes the same physical endpoint through several host APIs.
    The settings menu should not make users choose among implementation
    details, so exact device names are grouped case-insensitively and the
    most suitable Windows backend is retained (WASAPI first). System-default
    aliases are hidden whenever at least one concrete endpoint exists.

    This is deliberately a presentation helper: runtime resolution still
    receives the complete enumeration and remains strict about the persisted
    ``(name, host_api)`` pair.
    """

    concrete = [
        endpoint
        for endpoint in endpoints
        if endpoint.name.strip().casefold() not in _WINDOWS_DEFAULT_OUTPUT_ALIASES
    ]
    candidates = concrete or list(endpoints)
    normalized_candidates = [
        (endpoint, " ".join(endpoint.name.split()).casefold())
        for endpoint in candidates
    ]
    candidates = [
        endpoint
        for endpoint, normalized_name in normalized_candidates
        if not (
            endpoint.host_api.strip().casefold() == "mme"
            and len(normalized_name) >= 30
            and any(
                other is not endpoint
                and _HOST_API_PREFERENCE.get(other.host_api.strip().casefold(), 99)
                < _HOST_API_PREFERENCE["mme"]
                and other_name.startswith(normalized_name)
                for other, other_name in normalized_candidates
            )
        )
    ]
    best_by_name: dict[str, tuple[int, int, AudioEndpoint]] = {}
    for position, endpoint in enumerate(candidates):
        normalized_name = " ".join(endpoint.name.split()).casefold()
        rank = _HOST_API_PREFERENCE.get(endpoint.host_api.strip().casefold(), 99)
        current = best_by_name.get(normalized_name)
        if current is None or (rank, position) < (current[0], current[1]):
            best_by_name[normalized_name] = (rank, position, endpoint)

    return [
        value[2]
        for value in sorted(best_by_name.values(), key=lambda value: value[1])
    ]


def resolve_selected_endpoint(
    endpoints: Sequence[AudioEndpoint],
    selected_name: Optional[str],
    selected_host_api: Optional[str] = None,
) -> AudioEndpoint:
    """Return the endpoint the user selected, or fail closed.

    Never picks a default or "closest match" endpoint: an empty selection, a
    selection that no longer exists, or an ambiguous selection (same display
    name exposed under more than one host API, e.g. WASAPI and MME both
    listing "Speakers") all raise, by design - name alone is not always a
    unique identity, so a saved ``selected_host_api`` disambiguates when
    present. If no host API was saved (older config, or a name that happens
    to be unique) and the name alone resolves to exactly one endpoint, that
    is accepted; if it resolves to more than one, this fails closed instead
    of guessing which one the user meant.
    """

    if not selected_name:
        raise AudioOutputUnavailableError(
            "no output endpoint has been selected; open settings and choose one"
        )

    name_matches = [endpoint for endpoint in endpoints if endpoint.name == selected_name]

    if not name_matches:
        raise AudioOutputUnavailableError(
            f"selected output endpoint is not currently present: {selected_name!r}"
        )

    if selected_host_api:
        host_api_matches = [
            endpoint for endpoint in name_matches if endpoint.host_api == selected_host_api
        ]
        if not host_api_matches:
            raise AudioOutputUnavailableError(
                f"selected output endpoint {selected_name!r} is no longer present "
                f"under host API {selected_host_api!r}"
            )
        # A saved host API is assumed unique per (name, host_api) pair.
        return host_api_matches[0]

    if len(name_matches) > 1:
        raise AudioOutputUnavailableError(
            f"{len(name_matches)} output endpoints are named {selected_name!r} across "
            "different host APIs; open settings and re-select one to disambiguate"
        )

    return name_matches[0]


def enumerate_output_endpoints() -> List[AudioEndpoint]:
    """Enumerate real Windows playback endpoints via ``sounddevice``/PortAudio.

    Windows-only in practice (PortAudio also runs on other platforms, but this
    project only ships a Windows client); guarded so importing this module
    never fails on a machine without the optional dependency installed.
    """

    return _enumerate_endpoints("max_output_channels")


def enumerate_input_endpoints() -> List[AudioEndpoint]:
    """Enumerate real Windows recording endpoints via ``sounddevice``/PortAudio
    (XRBM-031 In-scope item 11): needed only so the diagnostics page can
    confirm a VB-CABLE ``CABLE Output`` recording endpoint exists alongside
    the ``CABLE Input`` playback endpoint - this project's own voice path
    never reads from a recording endpoint itself (see
    ``resolve_selected_endpoint``, which is playback-only and unchanged).
    """

    return _enumerate_endpoints("max_input_channels")


def _enumerate_endpoints(channel_count_key: str) -> List[AudioEndpoint]:
    try:
        import sounddevice as sd  # type: ignore
    except ImportError as exc:  # pragma: no cover - exercised only on Windows
        raise AudioOutputUnavailableError(
            "the 'sounddevice' package is not installed; cannot enumerate "
            "audio endpoints"
        ) from exc

    try:
        host_apis = sd.query_hostapis()
        endpoints: List[AudioEndpoint] = []
        for device in sd.query_devices():
            if device.get(channel_count_key, 0) <= 0:
                continue
            host_api_name = host_apis[device["hostapi"]]["name"] if host_apis else ""
            endpoints.append(AudioEndpoint(name=device["name"], host_api=host_api_name))
        return endpoints
    except AudioOutputUnavailableError:
        raise
    except Exception as exc:  # noqa: BLE001 - fail closed on ANY real PortAudio/
        # sounddevice failure (a raw PortAudioError, an unexpected device
        # dict shape, etc.) rather than letting it propagate as a
        # differently-shaped exception callers/tests do not already handle
        # (XRBM-031 RETRY 1 item 2). The message is deliberately generic -
        # never str(exc) - since some PortAudio error strings can embed a
        # real device name/path, which this project's privacy contract
        # (config.py's FORBIDDEN_KEYS, logging_setup.py) forbids surfacing;
        # the original exception is still chained via ``from exc`` for a
        # developer inspecting a real traceback/log.
        raise AudioOutputUnavailableError(
            "PortAudio 音频端点查询失败"
        ) from exc


# Canonical VB-CABLE (Basic/Donationware) endpoint display names, as VB-Audio's
# own driver names them: the playback ("speaker") side the app writes decoded
# voice PCM to, and the recording ("microphone") side a recognizer reads from.
# Never used to auto-select anything - only to let the diagnostics page (XRBM-
# 031) report whether the optional driver is installed, and to recognize the
# one endpoint the "select detected CABLE Input" action is allowed to persist.
CABLE_INPUT_NAME = "CABLE Input"
CABLE_OUTPUT_NAME = "CABLE Output"
DJI_MIC_2_NAME_PREFIXES = ("DJI-MIC2", "DJI Mic 2", "DJI Mic2")


def _matches_cable_endpoint(name: str, canonical: str) -> bool:
    """True only if ``name`` is exactly ``canonical``, or ``canonical``
    followed by a parenthesized host-API/driver decoration Windows/PortAudio
    commonly appends (e.g. ``"CABLE Input (VB-Audio Virtual Cable)"``) -
    never a bare substring match, which could also accept an unrelated
    device whose name merely contains ``canonical`` as a fragment of a
    longer, different name (e.g. a hypothetical "CABLE Input Splitter Pro").
    """

    name = name.strip()
    if name == canonical:
        return True
    decorated_prefix = canonical + " ("
    return name.startswith(decorated_prefix) and name.endswith(")")


def is_cable_input_endpoint(name: str) -> bool:
    """True if ``name`` names VB-CABLE's playback ("CABLE Input") endpoint."""

    return _matches_cable_endpoint(name, CABLE_INPUT_NAME)


def is_cable_output_endpoint(name: str) -> bool:
    """True if ``name`` names VB-CABLE's recording ("CABLE Output") endpoint."""

    return _matches_cable_endpoint(name, CABLE_OUTPUT_NAME)


def is_dji_mic_2_input_endpoint(name: str) -> bool:
    """Matches DJI Mic 2 system recording endpoints without depending on or
    exposing the per-device suffix Windows may append to the display name.
    Localized Windows names commonly wrap the product token, for example
    ``Microphone (DJI-MIC2-xxxx Hands-Free)``. Match a bounded token anywhere
    in the endpoint name while still rejecting names such as ``DJI-MIC20``.
    """

    value = name.strip().casefold()
    for raw_prefix in DJI_MIC_2_NAME_PREFIXES:
        prefix = raw_prefix.casefold()
        search_from = 0
        while True:
            index = value.find(prefix, search_from)
            if index < 0:
                break
            end = index + len(prefix)
            before_is_boundary = index == 0 or not value[index - 1].isalnum()
            after_is_boundary = end == len(value) or not value[end].isalnum()
            if before_is_boundary and after_is_boundary:
                return True
            search_from = index + 1
    return False
