"""Static contract scans over apps/windows/rc003 source, mirroring (in Python,
so it runs cross-platform in CI) the checks build/check-public-boundary.ps1
performs at build time.

These are intentionally redundant with the PowerShell script: this file
proves the contract holds on every machine that can run Python, while the
PowerShell script is what actually gates a real Windows build.
"""

import ast
import re
import subprocess
import unittest
from pathlib import Path

_PACKAGE_ROOT = Path(__file__).resolve().parents[1] / "src" / "ovb_rc003"

_PY_FILES = sorted(_PACKAGE_ROOT.glob("*.py"))

# A real MAC address literal, e.g. AA:BB:CC:DD:EE:FF. This project must never
# contain one anywhere (not even as a documented example), since a documented
# example living in source is one accidental copy-paste away from becoming a
# real persisted value.
_MAC_ADDRESS_RE = re.compile(r"\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b")

_FORBIDDEN_BRANDING_TERMS = (
    "T1RemoteBridge", "V60PenBridge", "PV60",
    "汉王", "customer_license", "customer_entry",
)

# Matched separately (case-insensitive, word-boundary-ish) so it doesn't
# false-positive on the unrelated upstream GitHub org name
# "xxb26553663-star", which legitimately appears in provenance citations.
_FORBIDDEN_BRANDING_PATTERNS = (
    re.compile(r"2655\s*AI", re.IGNORECASE),
    re.compile(r"2655ai\.com", re.IGNORECASE),
)

_ELEVATION_MARKERS = (
    "runas", "ShellExecute", "IsUserAnAdmin", "RequireAdministrator",
    "PrivilegesRequired=admin",
)

_FORBIDDEN_BINARY_SUFFIXES = (".exe", ".dll", ".pyd", ".zip", ".xz")

# The SOLE, disclosed exception (XRBM-031): vb_cable_bundle.py launches the
# THIRD-PARTY vendor's own VB-CABLE setup UI with Windows' "runas"/UAC verb,
# only from a slot reached by an explicit user click plus a separate
# explicit confirmation - never to elevate this application's own process,
# and never for anything but that one vendor-controlled launch. Every other
# module in this package must stay elevation-free; see
# test_elevation_exception_is_scoped_to_the_vendor_vb_cable_launch_only
# below, which proves the exemption is not a blank check.
_ELEVATION_MARKER_EXEMPT_FILENAMES = frozenset({"vb_cable_bundle.py"})

# vb_cable_bundle.py/windows_diagnostics.py/qt_settings_app.py are the three
# SANCTIONED, reviewed modules for the explicit vendor-launch/read-only-
# diagnostics flow (XRBM-031) - qt_settings_app.py's DiagnosticsController
# only exposes a thin QML-facing wrapper (``launchVbCableSetup``) around
# vb_cable_bundle.py's own function, with no business logic of its own. A
# function name referencing VB-CABLE anywhere else would suggest a second,
# unreviewed install path.
_VBCABLE_FUNCTION_NAME_SCAN_EXEMPT_FILENAMES = frozenset(
    {"vb_cable_bundle.py", "windows_diagnostics.py", "qt_settings_app.py"}
)


class NoRealMacAddressLiteralsTests(unittest.TestCase):
    def test_source_files_contain_no_mac_address_literal(self):
        offenders = []
        for path in _PY_FILES:
            text = path.read_text(encoding="utf-8")
            if _MAC_ADDRESS_RE.search(text):
                offenders.append(str(path))
        self.assertEqual(offenders, [], f"MAC-address-shaped literal found in: {offenders}")


class NoForbiddenBrandingTests(unittest.TestCase):
    def test_python_package_contains_no_forbidden_branding(self):
        # Scoped to the actual application source (src/ovb_rc003), where a
        # forbidden term appearing at all would mean real branding leakage.
        # build/ and installer/ legitimately *reference* some of these terms
        # either as scanner patterns (check-public-boundary.ps1 has to name
        # what it scans for) or as "not included" documentation
        # (readme-rc003.txt explicitly states T1/V60 are NOT bundled); those
        # files are covered by the more targeted, comment-aware assertions in
        # tests/test_build_artifacts.py instead.
        offenders = []
        for path in _PY_FILES:
            text = path.read_text(encoding="utf-8")
            for term in _FORBIDDEN_BRANDING_TERMS:
                if term in text:
                    offenders.append((str(path), term))
            for pattern in _FORBIDDEN_BRANDING_PATTERNS:
                if pattern.search(text):
                    offenders.append((str(path), pattern.pattern))
        self.assertEqual(offenders, [], f"forbidden branding term found: {offenders}")


class NoElevationOrAutoDriverTests(unittest.TestCase):
    def test_no_admin_elevation_requested_in_source(self):
        offenders = []
        for path in _PY_FILES:
            if path.name in _ELEVATION_MARKER_EXEMPT_FILENAMES:
                continue
            text = path.read_text(encoding="utf-8")
            for marker in _ELEVATION_MARKERS:
                if marker in text:
                    offenders.append((str(path), marker))
        self.assertEqual(offenders, [], f"elevation marker found: {offenders}")

    def test_elevation_exception_is_scoped_to_the_vendor_vb_cable_launch_only(self):
        # Proves the exemption above is not a blank check: the one exempted
        # file must actually contain the elevation verb (or this exemption
        # would be dead weight), must never reference the Inno Setup admin
        # marker or a self-elevation API, and must apply "runas" to the
        # vendor's own extracted setup path - not this application's own
        # executable.
        path = _PACKAGE_ROOT / "vb_cable_bundle.py"
        text = path.read_text(encoding="utf-8")
        self.assertIn("runas", text)
        self.assertNotIn("PrivilegesRequired=admin", text)
        self.assertNotIn("RequireAdministrator", text)
        self.assertIn('os.startfile(path, "runas"', text)

    def test_no_vbcable_install_function_exists_outside_the_sanctioned_module(self):
        offenders = []
        for path in _PY_FILES:
            if path.name in _VBCABLE_FUNCTION_NAME_SCAN_EXEMPT_FILENAMES:
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    if "vbcable" in node.name.lower() or "vb_cable" in node.name.lower():
                        offenders.append((str(path), node.name))
        self.assertEqual(
            offenders, [], f"VB-CABLE-related function found outside the sanctioned module: {offenders}"
        )

    def test_vb_cable_bundle_module_never_defines_a_silent_or_auto_install_function(self):
        path = _PACKAGE_ROOT / "vb_cable_bundle.py"
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        offenders = [
            node.name
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and (
                "silent" in node.name.lower()
                or "auto_install" in node.name.lower()
                or "autoinstall" in node.name.lower()
            )
        ]
        self.assertEqual(offenders, [])

    def test_vb_cable_bundle_module_never_uses_silent_install_flags(self):
        path = _PACKAGE_ROOT / "vb_cable_bundle.py"
        text = path.read_text(encoding="utf-8").lower()
        for flag in ("/verysilent", "/silent", "/qn", "/quiet", "-silent", "--silent"):
            self.assertNotIn(flag, text)

    def test_pnputil_never_referenced_anywhere_in_source_except_as_documented_exclusion(self):
        # vb_cable_bundle.py's own docstring/comments explain, in prose, that
        # pnputil is never used - the word itself legitimately appears there
        # (same self-documentation pattern this project already exempts
        # elsewhere, e.g. readme-rc003.txt's "不包含 T1、V60..." line). Every
        # OTHER file must never mention it at all, and even inside
        # vb_cable_bundle.py the word must never share a line with an actual
        # process-invocation call.
        offenders = []
        for path in _PY_FILES:
            text = path.read_text(encoding="utf-8")
            if path.name != "vb_cable_bundle.py":
                if "pnputil" in text.lower():
                    offenders.append(str(path))
                continue
            for line in text.splitlines():
                lower = line.lower()
                if "pnputil" not in lower:
                    continue
                for invocation_marker in ("subprocess", "os.system", "popen", "startfile"):
                    if invocation_marker in lower:
                        offenders.append((str(path), line.strip()))
        self.assertEqual(offenders, [], f"pnputil reference found: {offenders}")

    def test_vb_cable_bundle_documents_the_pnputil_exclusion(self):
        path = _PACKAGE_ROOT / "vb_cable_bundle.py"
        self.assertIn("pnputil", path.read_text(encoding="utf-8").lower())


class NoBinariesCommittedTests(unittest.TestCase):
    def test_no_forbidden_binary_extensions_under_rc003(self):
        rc003_root = _PACKAGE_ROOT.parents[1]
        repository_root = rc003_root.parents[2]
        tracked = subprocess.run(
            ["git", "ls-files", "--", "apps/windows/rc003"],
            cwd=repository_root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        offenders = [
            path
            for path in tracked
            if Path(path).suffix.lower() in _FORBIDDEN_BINARY_SUFFIXES
        ]
        self.assertEqual(offenders, [], f"forbidden binary committed: {offenders}")


class ConfigPrivacyKeysNotHardcodedElsewhereTests(unittest.TestCase):
    def test_forbidden_config_keys_only_appear_in_config_module(self):
        # config.py is the one place allowed to reference these key names (to
        # define/guard against them). If any other module assigns a dict
        # literal key with one of these names, that's a real regression risk.
        offenders = []
        for path in _PY_FILES:
            if path.name == "config.py":
                continue
            text = path.read_text(encoding="utf-8")
            for key in ("address", "device_match", "interface_id", "device_token"):
                if re.search(rf'["\']{key}["\']\s*:', text):
                    offenders.append((str(path), key))
        self.assertEqual(offenders, [], f"forbidden identity key literal found: {offenders}")


class NoAutoStartOnLoginTests(unittest.TestCase):
    def test_source_never_references_startup_folder_or_run_key(self):
        offenders = []
        markers = ("CurrentVersion\\\\Run", "userstartup", "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run")
        for path in _PY_FILES:
            text = path.read_text(encoding="utf-8")
            for marker in markers:
                if marker in text:
                    offenders.append((str(path), marker))
        self.assertEqual(offenders, [], f"autostart marker found: {offenders}")


if __name__ == "__main__":
    unittest.main()
