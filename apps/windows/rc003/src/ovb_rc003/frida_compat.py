"""Optional, SHA-pinned Frida Gadget compatibility layer for the RC003 "back"
key only.

Background: the RC003's "back"/return button reports a HID Keyboard-page
usage (0x00F1) that Windows' own BLE HID-over-GATT translation does not
surface through normal Raw Input/keyboard events (see this package's
top-level README.md "Known gaps" section, which documents this as the
Back key gap).
Every other button is read directly via raw_input_windows.py and needs no
extra component.

Scope deliberately cut for this source/build candidate: this module provides
the SHA-pinned asset descriptor and an honest availability/degradation
contract, but does NOT implement the actual remote-process injection step
(that would require code that opens/writes another process's memory and is
out of scope for a pre-real-device-verification candidate that must not
request elevation or touch other processes). ``BackKeyCompatLayer.start()``
therefore always degrades: the back key simply stays unmapped until a future
task wires up verified, real-hardware-tested injection. This is a real,
disclosed gap, not a simulated pass.

No binary is bundled or downloaded by this repository. build/fetch-frida-
gadget.ps1 is the only place a network fetch happens, and it verifies the
official release artifact's SHA-256 before use.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ThirdPartyAsset:
    name: str
    version: str
    url: str
    sha256: str
    license_name: str
    license_url: str


# Official upstream release asset and its published SHA-256. Sourced from the
# Frida project's own GitHub Releases; not authored by, and not affiliated
# with, this project or its upstream reference.
FRIDA_GADGET = ThirdPartyAsset(
    name="Frida Gadget",
    version="17.15.3",
    url=(
        "https://github.com/frida/frida/releases/download/17.15.3/"
        "frida-gadget-17.15.3-windows-x86_64.dll.xz"
    ),
    sha256="b566d70189b6d551ad8f4e0bea24de08a3d4c0f559bb35b2bdb67d45182240c2",
    license_name="wxWindows Library Licence (Frida's own license)",
    license_url="https://raw.githubusercontent.com/frida/frida-core/main/COPYING",
)


def verify_asset(path: Path, asset: ThirdPartyAsset) -> bool:
    """True only if ``path`` exists and its SHA-256 matches ``asset`` exactly."""

    if not path.is_file():
        return False
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest.lower() == asset.sha256.lower()


class BackKeyCompatLayer:
    """Optional compatibility shim for the RC003 back key. Always degrades in
    this candidate; see module docstring.
    """

    def __init__(self, gadget_path: Path = None, asset: ThirdPartyAsset = FRIDA_GADGET):  # type: ignore[assignment]
        self._asset = asset
        self._gadget_path = gadget_path
        self._verified = gadget_path is not None and verify_asset(gadget_path, asset)

    @property
    def available(self) -> bool:
        """Whether a verified gadget artifact is present on disk.

        Even when True, ``start()`` still returns False in this candidate -
        the injector itself is not implemented yet.
        """

        return self._verified

    @property
    def status(self) -> str:
        if self._gadget_path is None:
            return "unavailable_no_path_configured"
        if not self._verified:
            return "unavailable_missing_or_hash_mismatch"
        return "verified_but_injector_not_implemented_in_candidate"

    def start(self) -> bool:
        """Always returns False in this candidate (see module docstring).

        Other buttons and voice are unaffected by this returning False; only
        the back key stays unmapped.
        """

        return False
