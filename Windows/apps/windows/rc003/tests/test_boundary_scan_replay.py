"""Replays build/check-public-boundary.ps1's exact scanning algorithm in
Python, against the real apps/windows/rc003 tree, so its scoping/allowlist
logic (see XRBM-014 review RETRY P1 #8) is covered by an automated test that
runs on any OS - not just when a real Windows/PowerShell runner exercises
the .ps1 script itself.

This deliberately reimplements the PS script's categories/exemption list
rather than importing it (PowerShell isn't guaranteed available here); if
you change one, change both and re-run this test to confirm they still
agree that the real tree passes with zero violations.
"""

import re
import hashlib
import tempfile
import unittest
from pathlib import Path

_RC003_ROOT = Path(__file__).resolve().parents[1]

# Mirrors $excludedDirNames in check-public-boundary.ps1 exactly - keep both
# lists in sync. Generated/build-output directories, never source: a real
# Python virtualenv's own binaries (.venv), PyInstaller's dist/work output
# (dist, pyinstaller-work), and vendored third-party binaries (third_party)
# routinely contain forbidden-binary-extension files that must never be
# treated as "committed" content.
_EXCLUDED_DIR_NAMES = {".venv", "dist", "pyinstaller-work", "third_party"}


def _is_excluded_generated_path(path: Path) -> bool:
    """Match both canonical and timestamped build output directories."""
    return any(
        part in _EXCLUDED_DIR_NAMES
        or part.startswith("dist-")
        or part.startswith("build-")
        or part.startswith("pyinstaller-work-")
        for part in path.parts
    )

_FORBIDDEN_BINARY_EXTENSIONS = {".exe", ".dll", ".pyd", ".zip", ".xz"}
_OPTIONAL_FRIDA_GADGET_RELATIVE_PATH = Path(
    "src/ovb_rc003/frida_assets/frida-gadget-17.15.3-windows-x86_64.dll.xz"
)
_OPTIONAL_FRIDA_GADGET_SHA256 = (
    "b566d70189b6d551ad8f4e0bea24de08a3d4c0f559bb35b2bdb67d45182240c2"
)
_TEXT_EXTENSIONS = {
    ".py", ".ps1", ".md", ".txt", ".json", ".yml", ".yaml", ".iss", ".spec", ".toml"
}

_MAC_ADDRESS_RE = re.compile(r"([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}")
_MAC_ADDRESS_PLACEHOLDER = "AA:BB:CC:DD:EE:FF"
_PERSONAL_PATH_RE = re.compile(r"[A-Za-z]:\\Users\\[^\\\"'\s]+")
_CREDENTIAL_RE = re.compile(
    r"(api[_-]?key|client[_-]?secret|password)\s*[:=]\s*[\"'][^\"']{8,}[\"']"
)
_FORBIDDEN_BRANDING_PATTERNS = [
    re.compile(pattern)
    for pattern in (r"2655\s*AI", r"2655ai\.com", "T1RemoteBridge", "V60PenBridge", "PV60", "汉王")
]
_ELEVATION_MARKERS = (
    "runas", "ShellExecute", "IsUserAnAdmin", "RequireAdministrator", "PrivilegesRequired=admin"
)
_AUTOSTART_MARKERS = ("CurrentVersion\\Run", "userstartup")

# Mirrors $brandingCheckExemptRelativePaths in check-public-boundary.ps1
# exactly - keep both lists in sync. One shared list gates all three
# categories (branding/elevation/autostart) together, matching the PS1
# script's own single `$isExempt` flag. XRBM-031 adds
# src/ovb_rc003/vb_cable_bundle.py: it legitimately requests Windows' own
# "runas"/UAC verb to launch the THIRD-PARTY VB-CABLE vendor's setup UI -
# and only that, only from an explicit user click - which is otherwise
# forbidden everywhere else in this source tree (see
# test_vb_cable_bundle_py_is_exempt_only_for_its_documented_elevation_reason
# below, which proves this exemption is not a blank check).
_BRANDING_CHECK_EXEMPT_RELATIVE_PATHS = {
    Path("tests/test_privacy_contract.py"),
    Path("tests/test_build_artifacts.py"),
    Path("tests/test_boundary_scan_replay.py"),
    Path("build/check-public-boundary.ps1"),
    Path("installer/readme-rc003.txt"),
    Path("src/ovb_rc003/vb_cable_bundle.py"),
    # XRBM-031: README.md/ATTRIBUTION.md document the same disclosed
    # "runas"/UAC vendor-launch mechanism in prose (see README.md's
    # "VB-CABLE driver helper" section and ATTRIBUTION.md's
    # qt_settings_app.py/vb_cable_bundle.py rows) - the word itself is
    # documentation, not a directive, matching installer/readme-rc003.txt's
    # own precedent above.
    Path("README.md"),
    Path("ATTRIBUTION.md"),
}

_COMMENT_PREFIX_BY_EXTENSION = {".ps1": "#", ".iss": ";"}


def _remove_comment_lines(text: str, extension: str) -> str:
    prefix = _COMMENT_PREFIX_BY_EXTENSION.get(extension)
    if prefix is None:
        return text
    return "\n".join(
        line for line in text.splitlines() if not line.strip().startswith(prefix)
    )


def _is_verified_optional_frida_gadget(path: Path, root: Path) -> bool:
    """Allow only the explicitly pinned, ignored runtime asset."""
    if path.relative_to(root).as_posix() != _OPTIONAL_FRIDA_GADGET_RELATIVE_PATH.as_posix():
        return False
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return False
    return digest.hexdigest() == _OPTIONAL_FRIDA_GADGET_SHA256


def _scan(root: Path):
    violations = []
    all_files = [path for path in root.rglob("*") if path.is_file()]
    all_files = [
        path for path in all_files if not _is_excluded_generated_path(path)
    ]

    for path in all_files:
        ext = path.suffix.lower()

        if ext in _FORBIDDEN_BINARY_EXTENSIONS and not _is_verified_optional_frida_gadget(
            path, root
        ):
            violations.append(f"forbidden binary committed: {path}")
            continue

        if ext not in _TEXT_EXTENSIONS:
            continue

        relative_path = path.relative_to(root)
        is_exempt = relative_path in _BRANDING_CHECK_EXEMPT_RELATIVE_PATHS

        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        for match in _MAC_ADDRESS_RE.finditer(text):
            if match.group(0).upper() != _MAC_ADDRESS_PLACEHOLDER:
                violations.append(f"MAC-address-shaped literal in: {path}")
                break

        if _PERSONAL_PATH_RE.search(text):
            violations.append(f"personal absolute path in: {path}")
        if _CREDENTIAL_RE.search(text):
            violations.append(f"credential-shaped literal in: {path}")

        if not is_exempt:
            effective_text = _remove_comment_lines(text, ext)
            for pattern in _FORBIDDEN_BRANDING_PATTERNS:
                if pattern.search(effective_text):
                    violations.append(f"forbidden branding ({pattern.pattern!r}) in: {path}")
            for marker in _ELEVATION_MARKERS:
                if marker in effective_text:
                    violations.append(f"elevation marker ({marker!r}) in: {path}")
            for marker in _AUTOSTART_MARKERS:
                if marker in effective_text:
                    violations.append(f"autostart marker ({marker!r}) in: {path}")

    return violations, len(all_files)


class BoundaryScanReplayTests(unittest.TestCase):
    def test_real_tree_has_zero_violations(self):
        violations, scanned_count = _scan(_RC003_ROOT)
        self.assertEqual(violations, [], f"boundary scan replay found: {violations}")
        self.assertGreater(scanned_count, 0)

    def test_exempt_files_legitimately_reference_a_forbidden_term(self):
        # Regression guard for the exact bug this replaces: without the
        # exemption (and, for .ps1/.iss, comment-stripping), these files
        # would self-match because they legitimately contain the
        # forbidden-term string literals that define what to scan for, a
        # negative-test fixture, a documented exclusion statement, an
        # explanatory comment, or (XRBM-031, vb_cable_bundle.py only) the
        # one disclosed, scoped elevation verb this project actually uses.
        for relative in _BRANDING_CHECK_EXEMPT_RELATIVE_PATHS:
            path = _RC003_ROOT / relative
            self.assertTrue(path.is_file(), f"expected exempt file missing: {path}")
            text = path.read_text(encoding="utf-8")
            contains_a_forbidden_term = (
                any(pattern.search(text) for pattern in _FORBIDDEN_BRANDING_PATTERNS)
                or any(marker in text for marker in _AUTOSTART_MARKERS)
                or any(marker in text for marker in _ELEVATION_MARKERS)
            )
            self.assertTrue(
                contains_a_forbidden_term,
                f"{relative} was expected to legitimately reference a forbidden term "
                "(as a scanner pattern, fixture, exclusion statement, or comment) - if "
                "it no longer does, it may not need to stay in the exemption list",
            )

    def test_vb_cable_bundle_py_is_exempt_only_for_its_documented_elevation_reason(self):
        # Proves the new exemption is scoped, not a blank check: the file
        # must reference the elevation verb (or the exemption is dead
        # weight), and must never contain a forbidden BRANDING or AUTOSTART
        # term - only elevation is the reason it needed to be added here.
        path = _RC003_ROOT / "src" / "ovb_rc003" / "vb_cable_bundle.py"
        text = path.read_text(encoding="utf-8")
        self.assertTrue(any(marker in text for marker in _ELEVATION_MARKERS))
        self.assertFalse(any(pattern.search(text) for pattern in _FORBIDDEN_BRANDING_PATTERNS))
        self.assertFalse(any(marker in text for marker in _AUTOSTART_MARKERS))

    def test_readme_is_exempt_only_for_its_documented_elevation_reason(self):
        path = _RC003_ROOT / "README.md"
        text = path.read_text(encoding="utf-8")
        self.assertTrue(any(marker in text for marker in _ELEVATION_MARKERS))
        self.assertFalse(any(pattern.search(text) for pattern in _FORBIDDEN_BRANDING_PATTERNS))
        self.assertFalse(any(marker in text for marker in _AUTOSTART_MARKERS))

    def test_attribution_is_exempt_only_for_its_documented_elevation_reason(self):
        path = _RC003_ROOT / "ATTRIBUTION.md"
        text = path.read_text(encoding="utf-8")
        self.assertTrue(any(marker in text for marker in _ELEVATION_MARKERS))
        self.assertFalse(any(pattern.search(text) for pattern in _FORBIDDEN_BRANDING_PATTERNS))
        self.assertFalse(any(marker in text for marker in _AUTOSTART_MARKERS))

    def test_mac_placeholder_alone_does_not_violate(self):
        # test_config.py intentionally contains the standard placeholder as
        # a negative-test fixture proving rejection.
        path = _RC003_ROOT / "tests" / "test_config.py"
        text = path.read_text(encoding="utf-8")
        self.assertIn(_MAC_ADDRESS_PLACEHOLDER, text)
        violations, _ = _scan(_RC003_ROOT)
        self.assertFalse(any("test_config.py" in v and "MAC-address" in v for v in violations))

    def test_generated_directories_are_excluded_but_source_tree_binaries_are_not(self):
        # XRBM-022 controller pre-review correction: build-candidate.ps1
        # creates .venv/ (a real virtualenv full of .exe/.dll/.pyd files)
        # and dist/ + build/pyinstaller-work/ (PyInstaller output) BEFORE
        # calling the boundary scan, so without this exclusion a first
        # build could fail on its own freshly-created virtualenv binaries,
        # and a second (re-)run could additionally fail on the previous
        # run's dist/ output - the build script must be safely repeatable.
        # This must not become a blanket "ignore all .exe files" escape
        # hatch, so it also proves a real, non-generated source-tree binary
        # OUTSIDE any excluded directory is still rejected.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)

            generated_paths = [
                root / ".venv" / "Scripts" / "python.exe",
                root / ".venv" / "Lib" / "site-packages" / "something.pyd",
                root / "dist" / "RemoteMicRC003" / "RemoteMicRC003.exe",
                root / "dist" / "installer" / "RemoteMicRC003Setup-unsigned.exe",
                root / "build" / "pyinstaller-work" / "RemoteMicRC003" / "warn.txt.exe",
                root / "build" / "third_party" / "vendored.dll",
            ]
            for generated_path in generated_paths:
                generated_path.parent.mkdir(parents=True, exist_ok=True)
                generated_path.write_bytes(b"fake binary content")

            source_tree_exe = root / "src" / "ovb_rc003" / "accidentally_committed.exe"
            source_tree_exe.parent.mkdir(parents=True, exist_ok=True)
            source_tree_exe.write_bytes(b"fake binary content")

            violations, scanned_count = _scan(root)

            for generated_path in generated_paths:
                self.assertFalse(
                    any(str(generated_path) in v for v in violations),
                    f"generated file under an excluded directory was wrongly flagged: {generated_path}",
                )
            self.assertTrue(
                any(
                    "forbidden binary committed" in v and str(source_tree_exe) in v
                    for v in violations
                ),
                "a real source-tree binary outside every excluded directory must still be rejected",
            )
            # The excluded generated files must not even be counted as
            # scanned - they were never inspected at all, not merely
            # exempted from one category of check.
            self.assertEqual(scanned_count, 1)


if __name__ == "__main__":
    unittest.main()
