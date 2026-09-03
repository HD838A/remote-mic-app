"""Bundled, hash-gated VB-CABLE (Basic/Donationware) driver helper (XRBM-031).

Scope, drawn directly from this task's hard boundaries - read this before
touching anything below:

- VB-Audio's own VB-CABLE Basic package is Donationware: freely distributable
  as long as it stays visible/attributed/unmodified and the paid A+B/C+D
  bundles are never substituted for it (see
  <https://vb-audio.com/Services/licensing.htm>). This module only ever
  handles the ORIGINAL, unmodified ``VBCABLE_Driver_Pack45.zip`` - it never
  repacks, patches, or partially extracts it into something the vendor did
  not ship.
- This module never imports Qt/PySide6 (mirrors ``remote_layout.py``/
  ``shell_targets.py``'s Qt-free convention) - only ``qt_settings_app.py``'s
  ``DiagnosticsController`` calls into it, and only from a slot reached by an
  explicit user click plus a separate explicit confirmation (never
  automatically on page load/refresh).
- Every extraction path is verified against zip-slip (absolute paths, ``..``
  traversal, symlink members) BEFORE any file is written, and always into a
  freshly created, isolated temporary directory - never the application's own
  install/config directories.
- The vendor's OWN ``VBCABLE_Setup_x64.exe`` is launched with Windows' own
  ``runas`` verb (a real UAC elevation prompt the user can cancel) - never a
  silent/unattended install flag, never scripted UI automation, never a UAC
  bypass, never ``pnputil``, never a PowerShell execution-policy bypass, and
  never a direct driver-store write. Whether the driver ends up installed is
  only ever confirmed by a later, independent
  ``windows_diagnostics.check_vb_cable_endpoints()`` recheck (typically after
  the reboot the vendor installer itself requires) - launching the setup UI
  here is never reported as installation success.
- This project's own application installer/uninstaller never call anything
  in this module; only the settings window's diagnostics page does, and only
  on an explicit user click (see ``qt_settings_app.DiagnosticsController``).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Optional

# Windows' own ShellExecute-reported error code for "the user declined the
# UAC elevation prompt" (ERROR_CANCELLED). Not something this project chose;
# it's the platform's own documented value.
_UAC_CANCELLED_WINERROR = 1223


@dataclass(frozen=True)
class ThirdPartyAsset:
    name: str
    version: str
    url: str
    sha256: str


# Pinned exactly to the official VB-Audio download URL and the SHA-256
# computed from a real download of the official package taken on
# 2026-07-19. A future upstream
# package change MUST fail closed (verify_bundle() returns False) rather than
# silently accepting a different file under the same name - updating this
# pin requires a reviewed task, not a silent edit.
VB_CABLE_PACK45 = ThirdPartyAsset(
    name="VB-CABLE Driver Pack (Basic, Donationware)",
    version="Pack45",
    url="https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip",
    sha256="b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb",
)

PINNED_ZIP_FILENAME = "VBCABLE_Driver_Pack45.zip"

# The only member this candidate ever launches - the official 64-bit setup
# UI. VB-CABLE's Basic package also ships a 32-bit setup and driver .inf/.cat
# files; this candidate deliberately never selects or touches any of those,
# matching the "64-bit candidate" scope in the task's In-scope item 6.
REQUIRED_SETUP_MEMBER = "VBCABLE_Setup_x64.exe"

_READ_CHUNK_SIZE = 1024 * 1024


class VbCableBundleError(Exception):
    """Base class for every failure below - all fail closed (no partial/
    best-effort extraction or launch is ever left half-done and reported as
    success).
    """


class BundleNotFoundError(VbCableBundleError):
    """No bundled ZIP was found at all (this build was not produced via
    ``build/fetch-vb-cable.ps1``, or is running from a source checkout that
    never fetched one).
    """


class BundleHashMismatchError(VbCableBundleError):
    """The bundled ZIP's SHA-256 does not match the pinned value."""


class BundleZipUnsafeError(VbCableBundleError):
    """The ZIP contains a member this module refuses to extract (absolute
    path, ``..`` traversal, symlink, or missing the required setup exe).
    """


class VendorLaunchError(VbCableBundleError):
    """The vendor setup UI could not be launched (not the user cancelling
    UAC - see ``UacCancelledError`` for that distinct, non-error outcome).
    """


class UacCancelledError(VbCableBundleError):
    """The user declined the UAC elevation prompt. Nothing was installed;
    this is an expected, honest outcome, not a bug.
    """


@dataclass(frozen=True)
class ExtractedBundle:
    directory: Path
    setup_relative_path: str


def _candidate_bundle_paths(filename: str) -> Iterator[Path]:
    """Mirrors ``resources.py``'s frozen-vs-source-checkout lookup pattern:
    in a frozen (PyInstaller) build, ``build/RemoteMicRC003.spec``
    collects the verified ZIP under ``vb_cable_bundle/`` inside the COLLECT
    output (``sys._MEIPASS``-relative); in a source checkout,
    ``build/fetch-vb-cable.ps1`` writes it under ``build/third_party/``
    (gitignored - see that directory's own ``.gitignore`` entry), relative
    to this file's ``src/ovb_rc003/`` parent's RC003-root grandparent.
    """

    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root:
        yield Path(frozen_root) / "vb_cable_bundle" / filename
    # src/ovb_rc003/vb_cable_bundle.py -> rc003 root is parents[2].
    yield Path(__file__).resolve().parents[2] / "build" / "third_party" / filename


def find_bundle(
    asset: ThirdPartyAsset = VB_CABLE_PACK45,
    *,
    _search_paths: Optional[Iterator[Path]] = None,
) -> Optional[Path]:
    """Returns the first existing candidate path, or ``None``.
    ``_search_paths`` is a test-only injection seam (mirrors this package's
    other ``_candidate_paths()``-style lookups, e.g. ``resources.py``);
    production callers never pass it.
    """

    filename = Path(asset.url).name
    candidates = _search_paths if _search_paths is not None else _candidate_bundle_paths(filename)
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(_READ_CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_bundle(path: Path, asset: ThirdPartyAsset = VB_CABLE_PACK45) -> bool:
    """True only if ``path`` exists and its SHA-256 matches ``asset`` exactly
    (case-insensitive hex comparison). Never raises for a missing/unreadable
    file - callers that need a hard failure use ``extract_bundle``, which
    raises ``BundleHashMismatchError`` itself.
    """

    if not path.is_file():
        return False
    try:
        digest = _sha256_of(path)
    except OSError:
        return False
    return digest.lower() == asset.sha256.lower()


def _is_safe_member_name(name: str) -> bool:
    """Zip-slip defenses, applied to a member's raw ``filename`` BEFORE any
    file is written: rejects an absolute path (POSIX ``/...`` or a Windows
    drive-letter ``C:\\...``), a home-relative ``~...``, and any ``..``
    path segment (after normalizing backslashes to forward slashes, since a
    malicious ZIP can embed either separator regardless of platform).
    """

    if not name:
        return False
    normalized = name.replace("\\", "/")
    if normalized.startswith("/") or normalized.startswith("~"):
        return False
    if len(normalized) >= 2 and normalized[1] == ":":
        return False  # e.g. "C:/Windows/System32/evil.dll"
    return ".." not in normalized.split("/")


_ZIP_SYMLINK_UNIX_MODE = 0o120000
_ZIP_UNIX_MODE_MASK = 0o170000


def _is_symlink_member(info: zipfile.ZipInfo) -> bool:
    """A ZIP member's Unix file mode (when the archive was created on a
    Unix-like system, which the ``external_attr`` high 16 bits encode) can
    mark it as a symlink whose *content* is a target path rather than real
    file data - extracting that unmodified is another well-known ZIP-based
    path-escape vector distinct from a crafted member name. Rejected
    unconditionally: this project has no legitimate reason to ever see one
    inside an official VB-Audio Windows driver package.
    """

    mode = (info.external_attr >> 16) & 0xFFFF
    return (mode & _ZIP_UNIX_MODE_MASK) == _ZIP_SYMLINK_UNIX_MODE


def _find_setup_member(infos) -> Optional[str]:
    for info in infos:
        if Path(info.filename).name.lower() == REQUIRED_SETUP_MEMBER.lower():
            return info.filename
    return None


def extract_bundle(
    zip_path: Path, *, asset: ThirdPartyAsset = VB_CABLE_PACK45
) -> ExtractedBundle:
    """Verifies ``zip_path`` against the pinned hash, then safely extracts
    the ENTIRE original archive (never a partial/selective extraction - the
    vendor package must stay intact, per the Donationware "unmodified" term)
    into a freshly created, isolated temporary directory. Raises a distinct
    ``VbCableBundleError`` subclass on the first problem found; never
    extracts anything on any rejection path.
    """

    if not verify_bundle(zip_path, asset):
        raise BundleHashMismatchError(
            f"{zip_path} does not match the pinned SHA-256 for {asset.name}; "
            "refusing to extract a file that does not match the verified "
            "official package"
        )

    with zipfile.ZipFile(zip_path) as archive:
        infos = archive.infolist()
        if not infos:
            raise BundleZipUnsafeError("bundle ZIP has no members; refusing to extract")

        for info in infos:
            if not _is_safe_member_name(info.filename):
                raise BundleZipUnsafeError(
                    f"unsafe member path rejected: {info.filename!r}"
                )
            if _is_symlink_member(info):
                raise BundleZipUnsafeError(
                    f"symlink member rejected: {info.filename!r}"
                )

        setup_member = _find_setup_member(infos)
        if setup_member is None:
            raise BundleZipUnsafeError(
                f"required {REQUIRED_SETUP_MEMBER!r} not found in bundle; "
                "refusing to extract an incomplete/unexpected package"
            )

        extract_dir = Path(tempfile.mkdtemp(prefix="ovb_vbcable_"))
        resolved_root = extract_dir.resolve()
        try:
            for info in infos:
                archive.extract(info, path=extract_dir)
                extracted_path = (extract_dir / info.filename).resolve()
                if extracted_path != resolved_root and resolved_root not in extracted_path.parents:
                    raise BundleZipUnsafeError(
                        f"extracted member escaped the target directory: {info.filename!r}"
                    )
        except BaseException:
            # A partial extraction (a real I/O error mid-archive, or the
            # escape check above tripping after some earlier members were
            # already written) must never leave a half-populated temp
            # directory behind (XRBM-031 RETRY 1 item 4) - clean it up and
            # re-raise the ORIGINAL exception unchanged.
            shutil.rmtree(extract_dir, ignore_errors=True)
            raise

    return ExtractedBundle(directory=extract_dir, setup_relative_path=setup_member)


def _default_start_elevated(path: str, cwd: str) -> None:
    """Real launch: Windows' own ``ShellExecute`` "runas" verb via
    ``os.startfile`` - the exact mechanism double-clicking an installer and
    accepting its own UAC prompt uses. No silent-install argument is ever
    passed (``os.startfile`` takes no argument string here at all); no click
    automation; no UAC-bypass technique; no ``pnputil``; no PowerShell
    execution-policy bypass; no direct driver-store mutation. ``cwd`` (added
    in Python 3.10, which this project's ``py -3.12`` requirement satisfies)
    sets the extracted directory as the launched process's working
    directory, per the task's In-scope item 6.
    """

    if sys.platform != "win32":
        raise VendorLaunchError(
            "launching the vendor setup UI requires Windows (os.startfile 'runas')"
        )
    os.startfile(path, "runas", cwd=cwd)  # type: ignore[attr-defined,call-arg]


def launch_vendor_setup(
    extracted: ExtractedBundle,
    *,
    _start_elevated: Callable[[str, str], None] = _default_start_elevated,
) -> None:
    """Launches the ORIGINAL vendor setup UI, requesting UAC elevation.
    Raises ``UacCancelledError`` if the user declined the prompt,
    ``VendorLaunchError`` for any other launch failure, or
    ``BundleZipUnsafeError`` if the expected setup exe is somehow missing
    from the already-extracted directory. Never returns any "installed
    successfully" signal - only that the vendor UI was launched; see the
    module docstring.
    """

    setup_path = extracted.directory / extracted.setup_relative_path
    if not setup_path.is_file():
        raise BundleZipUnsafeError(
            f"expected setup executable missing after extraction: {setup_path}"
        )

    try:
        _start_elevated(str(setup_path), str(extracted.directory))
    except VbCableBundleError:
        raise
    except OSError as exc:
        if getattr(exc, "winerror", None) == _UAC_CANCELLED_WINERROR:
            raise UacCancelledError(
                "用户取消了 UAC 提升请求；未安装任何内容。"
            ) from exc
        raise VendorLaunchError(f"启动厂商安装程序失败：{exc}") from exc


def prepare_and_launch_vendor_setup(
    *,
    asset: ThirdPartyAsset = VB_CABLE_PACK45,
    _start_elevated: Callable[[str, str], None] = _default_start_elevated,
) -> ExtractedBundle:
    """The single entry point ``qt_settings_app.DiagnosticsController`` calls
    from its explicit-confirmation-gated slot: locate -> verify -> extract ->
    launch, in that order, raising a distinct ``VbCableBundleError`` subclass
    at the first problem. Returns the ``ExtractedBundle`` (kept only so a
    caller could log/report where it landed - this project's own logging
    never records the OS temp-path contents, only opaque status markers, per
    ``logging_setup.py``'s privacy contract).
    """

    bundle_path = find_bundle(asset)
    if bundle_path is None:
        raise BundleNotFoundError(
            f"{asset.name} bundle not found; this build was not produced "
            "with build/fetch-vb-cable.ps1"
        )
    extracted = extract_bundle(bundle_path, asset=asset)
    try:
        launch_vendor_setup(extracted, _start_elevated=_start_elevated)
    except BaseException:
        # No process ever started (a UAC cancellation, a missing setup exe,
        # or any other launch failure) - there is nothing left for the
        # extracted directory to still be useful for, so remove it rather
        # than leaking a temp directory on every failed attempt (XRBM-031
        # RETRY 1 item 4). Re-raises the ORIGINAL exception unchanged.
        shutil.rmtree(extracted.directory, ignore_errors=True)
        raise
    # A successful launch is deliberately NOT cleaned up here: the elevated
    # vendor process may still need adjacent files (e.g. driver .inf/.cat
    # files sitting next to the setup exe) for as long as it keeps running -
    # this project has no way to know when that process actually exits.
    return extracted
