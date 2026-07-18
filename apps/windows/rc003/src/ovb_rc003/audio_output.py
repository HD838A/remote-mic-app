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


class AudioOutputUnavailableError(Exception):
    """Raised whenever voice cannot be routed. Callers must fail the voice
    path closed on this (buttons keep working; only voice is affected).
    """


@dataclass(frozen=True)
class AudioEndpoint:
    name: str
    host_api: str = ""


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

    Windows-only in practice (PortAudio also runs on macOS/Linux, but this
    project only ships a Windows client); guarded so importing this module
    never fails on a machine without the optional dependency installed.
    """

    try:
        import sounddevice as sd  # type: ignore
    except ImportError as exc:  # pragma: no cover - exercised only on Windows
        raise AudioOutputUnavailableError(
            "the 'sounddevice' package is not installed; cannot enumerate "
            "audio output endpoints"
        ) from exc

    endpoints: List[AudioEndpoint] = []
    host_apis = sd.query_hostapis()
    for device in sd.query_devices():
        if device.get("max_output_channels", 0) <= 0:
            continue
        host_api_name = host_apis[device["hostapi"]]["name"] if host_apis else ""
        endpoints.append(AudioEndpoint(name=device["name"], host_api=host_api_name))
    return endpoints
