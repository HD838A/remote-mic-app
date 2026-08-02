import unittest
from pathlib import Path

RC003_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = RC003_ROOT.parents[2]


class PublicBoundaryTests(unittest.TestCase):
    def test_injection_components_are_not_present(self):
        forbidden_files = {
            "frida_compat.py",
            "frida_hid_tap_injector.py",
            "frida_hid_tap_runtime.py",
            "doubao_rpc.py",
            "vb_cable_bundle.py",
        }
        present = {
            path.name for path in (RC003_ROOT / "src" / "ovb_rc003").glob("*.py")
        }
        self.assertFalse(forbidden_files & present)

    def test_runtime_dependencies_include_qt_but_not_injection(self):
        requirements = (
            (RC003_ROOT / "requirements.txt").read_text(encoding="utf-8").lower()
        )
        for forbidden in ("frida", "pyqt"):
            self.assertNotIn(forbidden, requirements)
        self.assertIn("pyside6-essentials", requirements)

    def test_standard_button_mapping_components_are_present(self):
        source = RC003_ROOT / "src" / "ovb_rc003"
        for filename in (
            "raw_input_windows.py",
            "win32_input.py",
            "key_mapping.py",
            "hid_identity.py",
            "button_gesture.py",
            "action_executor.py",
        ):
            self.assertTrue((source / filename).is_file(), filename)

    def test_installer_does_not_bundle_or_install_vb_cable(self):
        installer = (
            (RC003_ROOT / "installer" / "RemoteMicRC003Setup.iss")
            .read_text(encoding="utf-8")
            .lower()
        )
        self.assertNotIn("vbcable", installer)
        self.assertNotIn("runas", installer)
        self.assertIn("privilegesrequired=lowest", installer)

    def test_stop_shortcut_uses_powershell_window_style_not_invalid_icon_flag(self):
        installer = (
            (RC003_ROOT / "installer" / "RemoteMicRC003Setup.iss")
            .read_text(encoding="utf-8")
            .lower()
        )
        icons = installer.split("[icons]", 1)[1].split("[run]", 1)[0]
        self.assertNotIn("runhidden", icons)
        self.assertIn("-windowstyle hidden", icons)

    def test_windows_workflow_is_separate_from_macos_packaging(self):
        workflow = (
            (REPO_ROOT / ".github" / "workflows" / "windows-rc003-ci.yml")
            .read_text(encoding="utf-8")
            .lower()
        )
        for forbidden in ("build-app.sh", "build-dmg.sh", "notarytool", "sparkle"):
            self.assertNotIn(forbidden, workflow)
        self.assertIn("windows-latest", workflow)


if __name__ == "__main__":
    unittest.main()
