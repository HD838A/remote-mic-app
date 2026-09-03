"""RC003 device discovery matching with a strict fail-closed policy.

This module intentionally does NOT persist, accept, or require a manual
Bluetooth address. It only decides, given whatever candidates the platform
transport discovered this run, whether there is exactly one RC003 to connect
to. Any ambiguity closes (refuses to guess) rather than picking a "best"
candidate or falling back to a previously remembered address - a deliberate
hardening versus the upstream reference implementation, which instead
persisted the resolved MAC address to disk and silently reused it (see
XRBM-014 for the citation and rationale).

Pure Python, no platform dependency: candidates are opaque to this module
beyond the name/hardware-match facts needed to decide.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Sequence

from . import device_profile


class RC003IdentityError(Exception):
    """Base class for identity-resolution failures. All are fail-closed."""


class NoCandidateFoundError(RC003IdentityError):
    """No paired/advertising device matched the RC003 identity at all."""


class AmbiguousCandidateError(RC003IdentityError):
    """More than one equally-qualified candidate was found; refusing to guess."""

    def __init__(self, count: int):
        super().__init__(
            f"{count} RC003 candidates found; keep only one paired device and retry"
        )
        self.count = count


@dataclass(frozen=True)
class RC003Candidate:
    """A transport-discovered candidate device.

    ``handle`` is an opaque, transport-specific reference (e.g. a WinRT
    device-information object) used only to open the connection; this module
    never inspects or persists it.
    """

    name: str
    hardware_match: bool
    handle: Any = None


def normalize_name(name: str) -> str:
    return name.strip().lower()


def matches_rc003_name(name: str) -> bool:
    return normalize_name(name) in device_profile.BLUETOOTH_NAMES


def select_single_candidate(candidates: Sequence[RC003Candidate]) -> RC003Candidate:
    """Return the sole qualifying candidate, or fail closed.

    A candidate qualifies if its advertised name matches one of the exact
    RC003 names, or the transport already confirmed a hardware VID/PID match.
    Zero qualifying candidates -> NoCandidateFoundError. Two or more -> always
    AmbiguousCandidateError, even if their names differ - the caller must not
    pick a "most likely" one.
    """

    qualifying = [
        candidate
        for candidate in candidates
        if candidate.hardware_match or matches_rc003_name(candidate.name)
    ]

    if not qualifying:
        raise NoCandidateFoundError("no paired RC003 candidate was discovered")
    if len(qualifying) > 1:
        raise AmbiguousCandidateError(len(qualifying))
    return qualifying[0]
