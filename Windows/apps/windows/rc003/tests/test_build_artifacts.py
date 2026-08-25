"""Static checks over the build/installer/CI sources themselves - not a
Windows build, just structural/contract validation that runs anywhere.
"""

import ast
import re
import unittest
from pathlib import Path

from ovb_rc003 import config, logging_setup

_RC003_ROOT = Path(__file__).resolve().parents[1]
_REPO_ROOT = _RC003_ROOT.parents[2]
_SPEC_PATH = _RC003_ROOT / "build" / "RemoteMicRC003.spec"
_REQUIREMENTS_PATH = _RC003_ROOT / "requirements.txt"
_ISS_PATH = _RC003_ROOT / "installer" / "RemoteMicRC003Setup.iss"
_CI_PATH = _REPO_ROOT / ".github" / "workflows" / "windows-rc003-ci.yml"
_PACKAGE_MAIN_PATH = _RC003_ROOT / "src" / "ovb_rc003" / "__main__.py"
_LAUNCHER_PATH = _RC003_ROOT / "src" / "launcher.py"
_BUILD_CANDIDATE_PATH = _RC003_ROOT / "build" / "build-candidate.ps1"
_README_PATH = _RC003_ROOT / "README.md"
_INSTALLED_README_PATH = _RC003_ROOT / "installer" / "readme-rc003.txt"
_ROOT_README_PATH = _REPO_ROOT / "README.md"
_THIRD_PARTY_NOTICES_PATH = _REPO_ROOT / "THIRD_PARTY_NOTICES.md"


def _exec_as_top_level_no_package(path: Path, *, module_name: str) -> None:
    """Reproduces exactly the failure mode PyInstaller's bootloader creates
    for its ``Analysis()`` entry script: the script's own source is
    executed as a top-level module with no ``__package__`` at all,
    regardless of where the file lives on disk (XRBM-021 red baseline, see
    the XRBM-021 task book). A relative import (``from . import X``) inside
    that source then raises ``ImportError: attempted relative import with
    no known parent package`` - independent of what ``__name__`` happens to
    be, since Python's relative-import resolution keys off ``__package__``,
    not ``__name__``.

    ``module_name`` deliberately avoids the literal string ``"__main__"``
    so this stays side-effect-free even against a script that guards its
    own execution with ``if __name__ == "__main__":`` - the import-time
    failure this test targets fires (or doesn't) before any such guard
    could ever run, so a real duplicate of PyInstaller's own ``__name__ ==
    "__main__"`` is not needed to reproduce or verify the fix.
    """

    source = path.read_text(encoding="utf-8")
    code = compile(source, str(path), "exec")
    namespace = {"__name__": module_name, "__package__": None, "__file__": str(path)}
    exec(code, namespace)


def _strip_hash_comments(text: str) -> str:
    """Drop '#'-comment lines (Python/.spec files) before scanning for
    forbidden *directives* - this file's own comments legitimately explain,
    in prose, which things are deliberately excluded, and that explanation
    should not itself trip a "must not mention X" check.
    """

    return "\n".join(
        line for line in text.splitlines() if not line.strip().startswith("#")
    )


def _strip_semicolon_comments(text: str) -> str:
    """Same idea as _strip_hash_comments, for Inno Setup's ';' comments."""

    return "\n".join(
        line for line in text.splitlines() if not line.strip().startswith(";")
    )


def _iss_section(text: str, name: str) -> str:
    """Extracts one Inno Setup ``[Name]`` section's body.

    A naive ``text.split("[Files]")`` is unsafe here: several of this
    script's own prose comments legitimately mention another section by
    its bracketed name (e.g. "...which [UninstallRun] and the Stop
    shortcut..."), which would silently split on that comment occurrence
    instead of the real section header. This only matches an actual
    section header - a line containing nothing but ``[Name]``.
    """

    match = re.search(
        rf"(?m)^\[{re.escape(name)}\][ \t]*\r?$\n(.*?)(?=^\[[A-Za-z]+\][ \t]*\r?$|\Z)",
        text,
        re.DOTALL,
    )
    assert match is not None, f"[{name}] section header not found"
    return match.group(1)


_WINRT_PIN_RE = re.compile(r"^winrt-Windows\.([A-Za-z0-9.]+)==3\.2\.1$")


def _winrt_requirement_modules(text: str) -> set:
    """Maps every exact ``winrt-Windows.<Namespace>==3.2.1`` pin in
    requirements.txt to the ``winrt.windows.<namespace>`` module name it
    installs (e.g. ``winrt-Windows.Foundation.Collections==3.2.1`` ->
    ``winrt.windows.foundation.collections``). Deliberately excludes
    ``winrt-runtime`` (not a ``winrt.windows.*`` namespace import).
    """

    modules = set()
    for line in text.splitlines():
        match = _WINRT_PIN_RE.match(line.strip())
        if match:
            modules.add("winrt.windows." + match.group(1).lower())
    return modules


def _spec_hidden_import_winrt_modules(text: str) -> set:
    tree = ast.parse(text, filename=str(_SPEC_PATH))
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "hiddenimports"
            for target in node.targets
        ):
            values = ast.literal_eval(node.value)
            return {value for value in values if value.startswith("winrt.")}
    raise AssertionError("hiddenimports assignment not found in spec")


class WinRTDependencyClosureContractTests(unittest.TestCase):
    """XRBM-024: deterministic, cross-platform proof that every exact
    ``winrt-Windows.*==3.2.1`` pin in requirements.txt has a matching
    PyInstaller hidden import, and vice versa - so the source-test/
    frozen-build dependency closure this task fixed (Foundation and
    Foundation.Collections missing from both) cannot silently drift apart
    again for any winrt-Windows.* projection, present or future.
    """

    def setUp(self):
        self.requirements_text = _REQUIREMENTS_PATH.read_text(encoding="utf-8")
        self.spec_text = _SPEC_PATH.read_text(encoding="utf-8")

    def test_foundation_and_foundation_collections_are_pinned_at_exact_3_2_1(self):
        self.assertIn("winrt-Windows.Foundation==3.2.1", self.requirements_text)
        self.assertIn(
            "winrt-Windows.Foundation.Collections==3.2.1", self.requirements_text
        )

    def test_requirements_never_pulls_the_broad_all_extra(self):
        # XRBM-024 in-scope item 1: exact base-package pins only, never the
        # "[all]" extra, which would pull in every unrelated namespace those
        # packages' own "all" extras reference (ApplicationModel.Background,
        # Security.Credentials, UI, UI.Popups, Storage, System, Networking,
        # Radios, Rfcomm, ...). Checked against effective (non-comment)
        # content, since this file's own comment legitimately explains the
        # "not [all]" rule in prose.
        self.assertNotIn("[all]", _strip_hash_comments(self.requirements_text))

    def test_spec_declares_hidden_imports_for_foundation_and_foundation_collections(self):
        modules = _spec_hidden_import_winrt_modules(self.spec_text)
        self.assertIn("winrt.windows.foundation", modules)
        self.assertIn("winrt.windows.foundation.collections", modules)

    def test_every_pinned_winrt_windows_package_has_a_matching_hidden_import(self):
        pinned_modules = _winrt_requirement_modules(self.requirements_text)
        hidden_import_modules = _spec_hidden_import_winrt_modules(self.spec_text)
        self.assertTrue(
            pinned_modules, "no winrt-Windows.*==3.2.1 pins found in requirements.txt"
        )
        missing_hidden_imports = pinned_modules - hidden_import_modules
        self.assertEqual(
            missing_hidden_imports,
            set(),
            "requirements.txt pins a winrt-Windows.* projection with no "
            "matching PyInstaller hidden import - the frozen build would "
            "pass source tests and then crash at runtime: "
            f"{sorted(missing_hidden_imports)}",
        )

    def test_every_winrt_hidden_import_has_a_matching_requirements_pin(self):
        pinned_modules = _winrt_requirement_modules(self.requirements_text)
        hidden_import_modules = _spec_hidden_import_winrt_modules(self.spec_text)
        missing_pins = hidden_import_modules - pinned_modules
        self.assertEqual(
            missing_pins,
            set(),
            "PyInstaller hidden-imports a winrt.windows.* module with no "
            "matching requirements.txt pin - the frozen build's runtime "
            "closure is undocumented/unpinned: "
            f"{sorted(missing_pins)}",
        )


class PyInstallerSpecTests(unittest.TestCase):
    def test_spec_embeds_and_bundles_product_icon(self):
        text = _SPEC_PATH.read_text(encoding="utf-8")
        self.assertIn('APP_ICON = REPO_ROOT / "Resources" / "RemoteMic-AppIcon.ico"', text)
        self.assertIn('icon=str(APP_ICON)', text)
        self.assertIn('datas.append((str(APP_ICON), "Resources"))', text)

    def test_spec_is_valid_python(self):
        text = _SPEC_PATH.read_text(encoding="utf-8")
        ast.parse(text, filename=str(_SPEC_PATH))  # raises SyntaxError on failure

    def test_spec_excludes_other_device_bridges(self):
        text = _SPEC_PATH.read_text(encoding="utf-8")
        self.assertIn("bridges.t1", text)
        self.assertIn("bridges.hanvon", text)

    def test_spec_collects_only_an_optional_verified_frida_archive(self):
        # The archive is never stored in source control. When the explicit
        # fetch step supplies a .xz file, the spec may copy it as opaque data;
        # it must not hard-code a release filename or treat it as a linked
        # binary dependency.
        text = _strip_hash_comments(_SPEC_PATH.read_text(encoding="utf-8")).lower()
        self.assertIn("frida_assets", text)
        self.assertIn('glob("*.xz")', text)
        self.assertNotIn("frida-gadget-17.15.3-windows-x86_64.dll.xz", text)

    def test_spec_bundles_the_verified_vb_cable_zip_as_data_not_a_binary_dependency(self):
        # XRBM-031: unlike Frida, the pinned VB-CABLE base package IS now
        # bundled - but only as opaque `datas` (an ordinary file PyInstaller
        # copies verbatim), never as a `binaries`/hiddenimports entry that
        # would imply this project links against or executes vendor code at
        # build time. build/fetch-vb-cable.ps1 (a required gate in both
        # build-candidate.ps1 and windows-rc003-ci.yml, run BEFORE this spec)
        # is what actually places the verified file on disk; this spec stays
        # defensive (only bundles it if present), matching the existing
        # photo/qml datas entries.
        text = _strip_hash_comments(_SPEC_PATH.read_text(encoding="utf-8"))
        self.assertIn("VBCABLE_Driver_Pack45.zip", text)
        self.assertIn('"vb_cable_bundle"', text)
        self.assertIn("build", text)
        self.assertIn("third_party", text)
        self.assertIn('"ovb_rc003.vb_cable_bundle"', text)
        self.assertIn('"ovb_rc003.windows_diagnostics"', text)

    def test_spec_analyzes_the_standalone_launcher_not_the_package_main(self):
        # XRBM-021: the spec's Analysis() entry script must be
        # src/launcher.py - analyzing src/ovb_rc003/__main__.py directly
        # reproduces the red baseline's relative-import failure the moment
        # the frozen executable runs (see LauncherEntryPointTests below).
        # Checked against effective (non-comment) content, since this
        # file's own comment legitimately explains the "not __main__.py"
        # rule in prose.
        text = _strip_hash_comments(_SPEC_PATH.read_text(encoding="utf-8"))
        self.assertIn('SRC_ROOT / "launcher.py"', text)
        self.assertNotIn('SRC_ROOT / "ovb_rc003" / "__main__.py"', text)

    def test_spec_bundles_the_shared_device_profile_directory_as_data(self):
        text = _SPEC_PATH.read_text(encoding="utf-8")
        self.assertIn('DEVICE_PROFILES_DIR = REPO_ROOT / "device-profiles"', text)
        self.assertIn(
            'datas.append((str(DEVICE_PROFILES_DIR), "device-profiles"))', text
        )


class LauncherEntryPointTests(unittest.TestCase):
    """XRBM-021 In-scope item 1/5: structural regression coverage for the
    red baseline recorded in the XRBM-021 task book - an isolated
    PyInstaller 6.21.0 build of the PRE-FIX spec completed, but running the
    produced executable's `--dry-run` exited 1 with "ImportError: attempted
    relative import with no known parent package" from `__main__.py`. These
    tests reproduce that exact failure mode (and its fix) deterministically
    on any platform, without needing an actual PyInstaller build for every
    test run - the real isolated-environment build/`--dry-run` smoke test
    (see XRBM-021's implementation report) is the platform-level
    confirmation on top of this structural one.
    """

    def test_analyzing_the_package_main_directly_reproduces_the_red_failure(self):
        with self.assertRaises(ImportError) as ctx:
            _exec_as_top_level_no_package(
                _PACKAGE_MAIN_PATH, module_name="frozen_entry_simulation"
            )
        self.assertIn("relative import", str(ctx.exception))

    def test_the_standalone_launcher_exists_outside_the_package(self):
        self.assertTrue(_LAUNCHER_PATH.is_file())
        # No parent package: launcher.py must NOT live inside src/ovb_rc003/.
        self.assertNotEqual(_LAUNCHER_PATH.parent.name, "ovb_rc003")

    def test_the_standalone_launcher_uses_only_an_absolute_import(self):
        text = _LAUNCHER_PATH.read_text(encoding="utf-8")
        self.assertIn("from ovb_rc003.__main__ import main", text)
        # No package-relative import token anywhere in the launcher itself.
        for line in text.splitlines():
            stripped = line.strip()
            self.assertFalse(stripped.startswith("from ."))

    def test_the_standalone_launcher_avoids_the_red_failure(self):
        # Exercises the SAME no-parent-package execution context that broke
        # __main__.py above - the launcher's only import is absolute, so it
        # must succeed here too (ovb_rc003 is importable via this test
        # suite's own PYTHONPATH=src convention).
        _exec_as_top_level_no_package(
            _LAUNCHER_PATH, module_name="frozen_entry_simulation"
        )  # must not raise

    def test_the_standalone_launcher_still_guards_its_own_execution(self):
        # Structural check that launcher.py only calls main() when actually
        # run as a script (mirroring __main__.py's own guard) - it must not
        # call main() merely by being imported/analyzed.
        text = _LAUNCHER_PATH.read_text(encoding="utf-8")
        self.assertIn('if __name__ == "__main__":', text)


class InnoSetupScriptTests(unittest.TestCase):
    def setUp(self):
        self.text = _ISS_PATH.read_text(encoding="utf-8")
        self.effective_text = _strip_semicolon_comments(self.text)

    def test_privileges_required_is_lowest(self):
        self.assertIn("PrivilegesRequired=lowest", self.text)

    def test_no_autostart_shortcut_or_task(self):
        self.assertNotIn("userstartup", self.effective_text.lower())
        self.assertNotIn("Tasks: \"startup\"", self.effective_text)

    def test_no_vbcable_reference(self):
        # This installer SCRIPT's own directives never mention VB-CABLE at
        # all (checked against the effective, comment-stripped text) - it
        # never installs/configures/removes it, during install or
        # uninstall. The header COMMENT block (not checked by this
        # assertion) legitimately documents, in prose, that the bundled
        # APPLICATION carries it as optional data - see
        # test_header_comment_discloses_bundled_driver_helper_honestly
        # below for that.
        lower = self.effective_text.lower()
        self.assertNotIn("vbcable", lower)
        self.assertNotIn("vb-cable", lower)

    def test_header_comment_discloses_bundled_driver_helper_honestly(self):
        # XRBM-031 RETRY 1 item 5: the header comment previously claimed
        # "No VB-CABLE ... is installed, configured, or referenced" - false,
        # since the frozen application it packages DOES bundle the official
        # VB-CABLE package as data and can launch its setup UI from the
        # diagnostics page. The corrected comment must instead state
        # precisely what stays true (this installer script itself never
        # runs/removes the driver, never elevates) without denying the
        # bundled/launchable reality.
        self.assertIn("vb-cable", self.text.lower())
        self.assertIn("检查与修复", self.text)
        self.assertIn("UAC", self.text)
        self.assertNotIn(
            "no vb-cable or any other driver package is installed, configured, or",
            self.text.lower(),
        )

    def test_install_dir_uses_open_voice_bridge_namespace(self):
        self.assertIn(r"{localappdata}\RemoteMic\{#AppFolder}", self.text)

    def test_app_name_has_no_forbidden_branding(self):
        self.assertNotIn("2655", self.text)
        self.assertNotIn("T1RemoteBridge", self.text)
        self.assertNotIn("V60PenBridge", self.text)

    def test_uninstall_run_stops_the_app_first(self):
        self.assertIn("stop-app.ps1", self.text)

    def test_stop_app_script_is_both_temp_extractable_and_permanently_installed(self):
        # XRBM-022: the round-1 defect was that stop-app.ps1 only had a
        # "dontcopy" [Files] entry (extractable during PrepareToInstall) and
        # was never actually installed to {app} - so [UninstallRun] and any
        # Stop shortcut referencing "{app}\stop-app.ps1" pointed at a file
        # that never existed on disk after install. Both entries must exist.
        files_section = _iss_section(self.text, "Files")
        self.assertIn(
            'Source: "stop-app.ps1"; DestDir: "{app}"; Flags: ignoreversion',
            files_section,
        )
        self.assertIn(
            'Source: "stop-app.ps1"; DestDir: "{tmp}"; Flags: dontcopy',
            files_section,
        )

    def test_uninstall_run_and_a_stop_shortcut_both_target_the_installed_copy(self):
        # At least two independent references to the installed (not
        # temp-extracted) copy: [UninstallRun] and an explicit Stop shortcut.
        self.assertGreaterEqual(self.text.count(r"{app}\stop-app.ps1"), 2)

    def test_primary_start_menu_shortcut_opens_settings_not_bridge(self):
        self.assertIn(
            'Name: "{group}\\{#AppName}"; Filename: "{app}\\{#AppPayloadDir}\\{#AppExeName}"; Parameters: "--settings"',
            self.text,
        )

    def test_desktop_shortcut_opens_settings_not_bridge(self):
        self.assertIn(
            'Name: "{userdesktop}\\{#AppName}"; Filename: "{app}\\{#AppPayloadDir}\\{#AppExeName}"; '
            'Parameters: "--settings"; Tasks: desktopicon',
            self.text,
        )

    def test_explicit_settings_start_stop_uninstall_shortcuts_all_exist(self):
        icons_section = _iss_section(self.text, "Icons")
        self.assertIn("设置", icons_section)
        self.assertIn("启动 {#AppName}", icons_section)
        self.assertIn("停止 {#AppName}", icons_section)
        self.assertIn("卸载 {#AppName}", icons_section)

    def test_start_shortcut_uses_the_explicit_bridge_flag(self):
        # The no-argument exe now opens the settings window, so the Start
        # Menu "启动" entry must request bridge mode explicitly.
        self.assertIn(
            'Name: "{group}\\启动 {#AppName}"; Filename: "{app}\\{#AppPayloadDir}\\{#AppExeName}"; '
            'Parameters: "--bridge"',
            self.text,
        )

    def test_in_place_upgrade_replaces_only_program_payload(self):
        delete_section = _strip_semicolon_comments(
            _iss_section(self.text, "InstallDelete")
        )
        self.assertIn(
            'Type: filesandordirs; Name: "{app}\\{#AppPayloadDir}"',
            delete_section,
        )
        self.assertNotIn(r'Name: "{app}\\*"', delete_section)
        for runtime_name in (
            "config.json",
            "key_bindings.json",
            "usage-statistics.json",
            "logs",
        ):
            self.assertNotIn(runtime_name, delete_section)

    def test_in_place_upgrade_migrates_previous_flat_pyinstaller_layout(self):
        delete_section = _iss_section(self.text, "InstallDelete")
        self.assertIn(
            'Type: files; Name: "{app}\\{#AppExeName}"', delete_section
        )
        self.assertIn(
            'Type: filesandordirs; Name: "{app}\\_internal"', delete_section
        )

    def test_application_files_are_installed_below_replaceable_payload(self):
        files_section = _iss_section(self.text, "Files")
        self.assertIn(
            'Source: "{#DistDir}\\*"; DestDir: "{app}\\{#AppPayloadDir}"',
            files_section,
        )

    def test_postinstall_run_opens_settings_and_never_the_bare_no_arg_bridge(self):
        run_section = _iss_section(self.text, "Run")
        self.assertIn("postinstall", run_section)
        self.assertIn("--settings", run_section)
        # The bare (no-argument) form would start bridge mode - BLE/HID/audio
        # - before the user has configured anything. Only one [Run] entry
        # exists in this file, and it must carry --settings.
        self.assertEqual(run_section.count("Filename:"), 1)

    def test_copyright_is_packaged_alongside_license_and_notices(self):
        self.assertIn('DestName: "COPYRIGHT.txt"', self.text)
        self.assertIn('DestName: "THIRD_PARTY_NOTICES.md"', self.text)
        self.assertIn('DestName: "LICENSE.txt"', self.text)


class WindowsCiWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = _CI_PATH.read_text(encoding="utf-8")

    def test_targets_windows_runner(self):
        self.assertIn("windows-latest", self.text)

    def test_scoped_to_rc003_paths(self):
        self.assertIn("apps/windows/rc003/**", self.text)

    def test_runs_public_boundary_scan(self):
        self.assertIn("check-public-boundary.ps1", self.text)

    def test_runs_test_suite(self):
        self.assertIn("unittest discover", self.text)

    def test_attempts_pyinstaller_build(self):
        self.assertIn("PyInstaller", self.text)

    def test_runs_dry_run_smoke_check(self):
        self.assertIn("--dry-run", self.text)

    def test_compiles_inno_setup_installer(self):
        self.assertIn("ISCC.exe", self.text)

    def test_inno_setup_compile_is_a_required_gate_not_best_effort(self):
        # XRBM-018: promoted from best-effort/continue-on-error to a
        # required gate - a flaky/missing Inno Setup toolchain on the
        # runner must fail the job, not be silently skipped. Checked
        # against the effective (non-comment) YAML: this file's own prose
        # explains the change using that phrase, which is documentation,
        # not a directive.
        self.assertNotIn("continue-on-error", _strip_hash_comments(self.text))

    def test_never_runs_the_compiled_installer(self):
        lower = self.text.lower()
        self.assertNotIn("start-process", lower)
        self.assertNotIn("/verysilent", lower)
        self.assertNotIn("/silent", lower)

    def test_uses_current_supported_action_majors(self):
        # XRBM-022: upgrade from checkout@v4/setup-python@v5/upload-artifact@v4.
        self.assertIn("actions/checkout@v7", self.text)
        self.assertIn("actions/setup-python@v6", self.text)
        self.assertEqual(self.text.count("actions/upload-artifact@v7"), 1)
        self.assertNotIn("actions/checkout@v4", self.text)
        self.assertNotIn("actions/setup-python@v5", self.text)
        self.assertNotIn("actions/upload-artifact@v4", self.text)

    def test_exactly_one_upload_step_runs_after_every_required_gate(self):
        # XRBM-022 controller pre-review correction: an earlier round
        # uploaded the raw PyInstaller output right after the dry-run smoke
        # check, BEFORE the Inno Setup compile gate - so a job whose Inno
        # step then failed could still leave a published artifact behind.
        # Exactly one upload-artifact step must exist, and it must appear
        # (textually, which matches step execution order in a linear GitHub
        # Actions job) after the Inno compile and the deterministic
        # packaging step.
        self.assertEqual(self.text.count("uses: actions/upload-artifact@v7"), 1)
        iscc_index = self.text.index("ISCC.exe")
        package_index = self.text.index("Compress-Archive")
        upload_index = self.text.index("uses: actions/upload-artifact@v7")
        self.assertLess(iscc_index, upload_index)
        self.assertLess(package_index, upload_index)

    def test_triggers_on_files_the_installer_and_spec_consume_outside_rc003(self):
        # XRBM-022 controller pre-review correction: the installer (.iss)
        # packages root COPYRIGHT/LICENSE/THIRD_PARTY_NOTICES.md, and the
        # device-profiles/xiaomi-rc003.json documents identity/HID facts
        # this Windows adapter mirrors - none of these live under
        # apps/windows/rc003/, so the path-scoped trigger above would
        # otherwise silently skip CI on a change to any of them.
        #
        # Matched as an exact YAML list-item LINE (leading "      - "),
        # not a bare substring: the portable-packaging step below also
        # quotes some of these same filenames as Copy-Item destination
        # names (e.g. `(Join-Path $stagingDir "THIRD_PARTY_NOTICES.md")`),
        # which is unrelated to the push/pull_request trigger list and
        # must not be counted as a trigger occurrence.
        for path_trigger in (
            "COPYRIGHT.md",
            "LICENSE.md",
            "THIRD_PARTY_NOTICES.md",
            "device-profiles/xiaomi-rc003.json",
        ):
            trigger_line = f'      - "{path_trigger}"'
            self.assertEqual(
                self.text.count(trigger_line),
                2,
                f'{trigger_line!r} must appear once under push.paths and once under pull_request.paths',
            )

    def test_pip_cache_uses_the_exact_requirements_dev_path(self):
        self.assertIn(
            "cache-dependency-path: apps/windows/rc003/requirements-dev.txt",
            self.text,
        )

    def test_test_suite_is_gated_by_resource_warning(self):
        self.assertIn("-W error::ResourceWarning -m unittest discover", self.text)

    def test_test_suite_step_is_verbose_unbuffered_and_bounded(self):
        # Regression for XRBM-023: both canceled real-Windows-CI runs
        # produced only a single buffered "E.......F<235 dots>" line with no
        # test names at all, and the job had no step-level bound - a future
        # hang would again consume the runner up to the 360-minute job
        # default with no way to identify which test hung. The test step
        # must run unittest verbosely (-v) with unbuffered output (-u /
        # PYTHONUNBUFFERED) so a hung test's name is actually flushed and
        # visible before a step-level timeout-minutes cancels the step.
        run_step_start = self.text.index("- name: Run test suite")
        next_step_start = self.text.index("- name:", run_step_start + 1)
        run_step_text = self.text[run_step_start:next_step_start]

        self.assertIn("timeout-minutes:", run_step_text)
        self.assertIn("PYTHONUNBUFFERED", run_step_text)
        self.assertIn("python -u -W error::ResourceWarning -m unittest discover", run_step_text)
        self.assertIn(
            '-m unittest discover -s tests -t . -p "test_*.py" -v', run_step_text
        )

    def test_test_suite_step_hard_gates_late_resourcewarning_output(self):
        # XRBM-026: real Windows run 29644660267 completed 425 tests with
        # "OK (skipped=3)", then printed an ignored ResourceWarning for one
        # unclosed ProactorEventLoop and two unclosed self-pipe sockets -
        # AFTER unittest's own summary, so -W error::ResourceWarning alone
        # never saw it and the step still exited 0 (a warning-turned-
        # exception raised inside a __del__/finalizer at interpreter
        # shutdown is unraisable and cannot change an already-computed exit
        # code). The step must capture its full output to a file (so the
        # -v/unbuffered live Actions-log stream is unaffected) and then
        # scan that file's CONTENT - independent of $LASTEXITCODE - for
        # every one of these forbidden markers, failing the step if any
        # appear (see tests/test_resourcewarning_gate_replay.py for the
        # pure-Python replay of this exact detection logic).
        run_step_start = self.text.index("- name: Run test suite")
        next_step_start = self.text.index("- name:", run_step_start + 1)
        run_step_text = self.text[run_step_start:next_step_start]

        self.assertIn("Tee-Object -FilePath", run_step_text)
        self.assertIn("Get-Content -Path $logPath -Raw", run_step_text)
        self.assertIn("[regex]::Escape($pattern)", run_step_text)
        for pattern in ("ResourceWarning:", "unclosed event loop", "unclosed <socket.socket"):
            self.assertIn(f'"{pattern}"', run_step_text)

    def test_resourcewarning_pattern_requires_the_colon_to_avoid_self_collision(self):
        # A bare "ResourceWarning" (no colon) would match this very test
        # suite's own class name (tests/test_resourcewarning_gate_replay.py's
        # ResourceWarningGateReplayTests), printed verbatim by unittest's -v
        # output - making the gate fail on its own passing regression tests.
        # Real CPython warning/exception output always renders as
        # "ResourceWarning: <message>", so requiring the colon is both safe
        # and sufficient (see tests/test_resourcewarning_gate_replay.py for
        # the full false-positive proof).
        run_step_start = self.text.index("- name: Run test suite")
        next_step_start = self.text.index("- name:", run_step_start + 1)
        run_step_text = self.text[run_step_start:next_step_start]
        self.assertIn('"ResourceWarning:"', run_step_text)
        self.assertNotIn('"ResourceWarning",', run_step_text)

    def test_packages_deterministic_zip_and_sha256sums(self):
        self.assertIn("Compress-Archive", self.text)
        self.assertIn("Get-FileHash", self.text)
        self.assertIn("SHA256SUMS.txt", self.text)
        self.assertIn("-portable-unsigned.zip", self.text)

    def test_portable_zip_stages_license_copyright_notices_attribution_and_readme(self):
        # XRBM-022 controller pre-review correction: the portable ZIP
        # previously compressed only the bare PyInstaller output
        # (dist/RemoteMicRC003/*), so a user who only downloaded the
        # portable ZIP - never the installer - got no license, copyright,
        # third-party attribution/provenance, or usage instructions at all.
        # Each of these five files must be staged into the versioned
        # portable folder, matching what the installer itself packages
        # (LICENSE.txt/COPYRIGHT.txt/THIRD_PARTY_NOTICES.md) plus the two
        # extras the installer doesn't need but a bare portable ZIP does
        # (ATTRIBUTION.md's file-by-file provenance record, and the
        # installed readme repurposed as README.txt for usage instructions).
        self.assertIn(
            'Copy-Item -Path "../../../LICENSE.md" -Destination (Join-Path $stagingDir "LICENSE.txt")',
            self.text,
        )
        self.assertIn(
            'Copy-Item -Path "../../../COPYRIGHT.md" -Destination (Join-Path $stagingDir "COPYRIGHT.txt")',
            self.text,
        )
        self.assertIn(
            'Copy-Item -Path "../../../THIRD_PARTY_NOTICES.md" -Destination (Join-Path $stagingDir "THIRD_PARTY_NOTICES.md")',
            self.text,
        )
        self.assertIn(
            'Copy-Item -Path "ATTRIBUTION.md" -Destination (Join-Path $stagingDir "ATTRIBUTION.md")',
            self.text,
        )
        self.assertIn(
            'Copy-Item -Path "installer/readme-rc003.txt" -Destination (Join-Path $stagingDir "README.txt")',
            self.text,
        )

    def test_portable_metadata_files_are_staged_before_compress_archive_runs(self):
        # Staging each file is necessary but not sufficient - it must also
        # happen BEFORE Compress-Archive runs, or the ZIP would still be
        # missing them regardless of the Copy-Item lines existing somewhere
        # in the step. A linear pwsh script's step order is exactly its
        # textual (line) order.
        compress_index = self.text.index("Compress-Archive -Path $stagingDir")
        for destination_marker in (
            'Destination (Join-Path $stagingDir "LICENSE.txt")',
            'Destination (Join-Path $stagingDir "COPYRIGHT.txt")',
            'Destination (Join-Path $stagingDir "THIRD_PARTY_NOTICES.md")',
            'Destination (Join-Path $stagingDir "ATTRIBUTION.md")',
            'Destination (Join-Path $stagingDir "README.txt")',
        ):
            self.assertLess(
                self.text.index(destination_marker),
                compress_index,
                f"{destination_marker} must be staged before Compress-Archive runs",
            )

    def test_compress_archive_targets_the_staging_directory_not_the_bare_built_glob(self):
        # The archive source must be the STAGING folder (which contains a
        # copy of the built app plus the five metadata/instruction files
        # above), never the bare "dist/RemoteMicRC003/*" glob
        # directly - compressing that glob again would silently regress to
        # the pre-fix "no license/instructions in the ZIP" bug even if the
        # staging/copy lines above still existed elsewhere in the step.
        self.assertIn(
            "Compress-Archive -Path $stagingDir -DestinationPath $zipPath", self.text
        )
        self.assertNotIn(
            'Compress-Archive -Path "dist/RemoteMicRC003/*"', self.text
        )

    def test_compress_archive_uses_terminating_error_handling_not_lastexitcode(self):
        # XRBM-025 RETRY 1 (controller-accepted self-found blocker):
        # Compress-Archive is a PowerShell CMDLET, not a native command, so
        # it never sets $LASTEXITCODE - a stale/unset (always $null in this
        # step, since nothing native/script-based ran earlier)
        # $LASTEXITCODE made the old `if ($LASTEXITCODE -ne 0)` guard
        # unconditionally true, silently exiting the step with code 0
        # right after the ZIP was built, before the release directory was
        # ever staged or preflighted. The only correct fix is promoting
        # this cmdlet's own errors to terminating ones (-ErrorAction Stop)
        # and handling them with an explicit try/catch that exits nonzero
        # - never a $LASTEXITCODE inspection after a cmdlet.
        self.assertIn(
            "Compress-Archive -Path $stagingDir -DestinationPath $zipPath "
            "-CompressionLevel Optimal -ErrorAction Stop",
            self.text,
        )
        self.assertIn("try {", self.text)
        self.assertIn('Write-Error "Compress-Archive failed:', self.text)

    def test_no_lastexitcode_guard_follows_compress_archive(self):
        # The specific invalid pattern this RETRY removes must never
        # reappear immediately after Compress-Archive: scan the text
        # starting right after the Compress-Archive invocation, up to the
        # next non-blank pwsh statement, and assert it is not a
        # $LASTEXITCODE check.
        compress_index = self.text.index(
            "Compress-Archive -Path $stagingDir -DestinationPath $zipPath"
        )
        after_compress = self.text[compress_index:]
        catch_index = after_compress.index("} catch {")
        try_catch_block = after_compress[:catch_index]
        self.assertNotIn("$LASTEXITCODE", try_catch_block)

    def test_compress_archive_failure_exits_nonzero_inside_catch(self):
        step = self._package_step_text()
        try_index = step.index(
            "try {\n            Compress-Archive -Path $stagingDir"
        )
        catch_index = step.index("} catch {", try_index)
        release_dir_index = step.index('$releaseDir = "$env:GITHUB_WORKSPACE', catch_index)
        catch_block = step[catch_index:release_dir_index]
        self.assertIn("exit 1", catch_block)
        self.assertLess(catch_index, release_dir_index)

    def test_successful_archive_continues_into_release_staging_and_preflight(self):
        # The try/catch's happy path (no explicit "else"/continuation
        # marker needed - normal PowerShell try/catch control flow) must
        # fall straight through into the very next statements: installer
        # discovery, then release-directory staging ($releaseDir), then
        # the hard preflight - all textually after the try/catch block, in
        # the same step, none of them behind any other new guard.
        step = self._package_step_text()
        try_block_end = step.index("} catch {")
        installer_lookup_index = step.index(
            'Get-ChildItem -Path dist/installer -Filter "RemoteMicRC003Setup-*-unsigned.exe"'
        )
        release_dir_index = step.index('$releaseDir = "$env:GITHUB_WORKSPACE')
        preflight_index = step.index("$releaseFiles = @(Get-ChildItem -Path $releaseDir -File)")
        self.assertLess(try_block_end, installer_lookup_index)
        self.assertLess(installer_lookup_index, release_dir_index)
        self.assertLess(release_dir_index, preflight_index)

    def test_portable_staging_directory_is_a_single_versioned_top_level_folder(self):
        # Compress-Archive given a bare directory path (not a "/*" content
        # glob) wraps that directory itself as the ZIP's one top-level
        # entry - required so extracting the portable ZIP produces one
        # clearly-versioned folder, not loose files scattered at the
        # archive root.
        self.assertIn('$stagingName = "RemoteMicRC003-$version"', self.text)
        self.assertIn('$stagingDir = "dist/portable/$stagingName"', self.text)

    def _package_step_text(self):
        start = self.text.index(
            "- name: Package deterministic unsigned release directory"
        )
        end = self.text.index(
            "- name: Upload deterministic distribution artifacts", start
        )
        return self.text[start:end]

    def _upload_step_text(self):
        return self.text[
            self.text.index("- name: Upload deterministic distribution artifacts") :
        ]

    def test_release_directory_is_staged_from_the_final_zip_and_installer(self):
        # XRBM-024 RETRY: the release directory is a CLEAN copy target, not
        # the original dist/portable|installer locations - so a stale file
        # left over from a previous run can never leak into an upload.
        step = self._package_step_text()
        self.assertIn(
            '$releaseDir = "$env:GITHUB_WORKSPACE/apps/windows/rc003/dist/release"',
            step,
        )
        self.assertIn(
            "if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }",
            step,
        )
        self.assertIn(
            "Copy-Item -Path $zipPath -Destination $releaseZipPath -Force", step
        )
        self.assertIn(
            "Copy-Item -Path $installerExe.FullName -Destination $releaseInstallerPath -Force",
            step,
        )

    def test_release_directory_is_cleaned_before_the_copies_are_staged(self):
        step = self._package_step_text()
        clean_index = step.index(
            "if (Test-Path $releaseDir) { Remove-Item $releaseDir -Recurse -Force }"
        )
        zip_copy_index = step.index(
            "Copy-Item -Path $zipPath -Destination $releaseZipPath -Force"
        )
        installer_copy_index = step.index(
            "Copy-Item -Path $installerExe.FullName -Destination $releaseInstallerPath -Force"
        )
        self.assertLess(clean_index, zip_copy_index)
        self.assertLess(clean_index, installer_copy_index)

    def test_release_manifest_is_generated_from_the_staged_copies_not_the_originals(self):
        # The manifest must hash the files actually sitting in dist/release
        # - not the originals under dist/portable|installer - so a copy
        # failure (or any divergence between the two locations) is
        # reflected in the manifest the preflight below verifies.
        step = self._package_step_text()
        self.assertIn(
            "Get-FileHash -Algorithm SHA256 -LiteralPath $releaseZipPath", step
        )
        self.assertIn(
            "Get-FileHash -Algorithm SHA256 -LiteralPath $releaseInstallerPath", step
        )
        self.assertIn(
            "Set-Content -Path $releaseManifestPath -Value $lines -Encoding ascii",
            step,
        )
        self.assertNotIn("Set-Content -Path dist/SHA256SUMS.txt", step)

    def test_preflight_hard_checks_exactly_three_files_with_the_expected_names(self):
        step = self._package_step_text()
        self.assertIn("$releaseFiles.Count -ne 3", step)
        self.assertIn(
            '$expectedNames = @($zipName, $installerName, "SHA256SUMS.txt") | Sort-Object',
            step,
        )
        self.assertIn(
            "Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames",
            step,
        )

    def test_preflight_hard_checks_exactly_two_well_formed_manifest_lines(self):
        step = self._package_step_text()
        self.assertIn("$manifestLines.Count -ne 2", step)
        self.assertIn(
            r"'^(?<hash>[0-9a-f]{64})  (?<name>\S.*)$'", step
        )

    def test_preflight_verifies_every_manifest_entry_exists_and_hash_matches(self):
        step = self._package_step_text()
        self.assertIn("if (-not (Test-Path $filePath))", step)
        self.assertIn(
            "$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $filePath).Hash.ToLowerInvariant()",
            step,
        )
        self.assertIn("$actualHash -ne $expectedHash", step)

    def test_preflight_runs_before_the_upload_step(self):
        preflight_index = self.text.index(
            "$releaseFiles = @(Get-ChildItem -Path $releaseDir -File)"
        )
        upload_index = self.text.index("uses: actions/upload-artifact@v7")
        self.assertLess(preflight_index, upload_index)

    def test_upload_path_is_the_single_release_directory_not_a_multi_pattern_list(self):
        # XRBM-024 RETRY red evidence: a real Windows run (29643494504)
        # reported every step green, but the upload-artifact log itself
        # said "With the provided path, there will be 2 files uploaded" and
        # the downloaded artifact was missing SHA256SUMS.txt entirely -
        # because `if-no-files-found: error` only proves at least one of
        # several independent glob patterns matched something, never that
        # every declared pattern did. The fix uploads a single,
        # already-hard-verified directory instead of a multi-pattern list.
        #
        # XRBM-025 RETRY: the single pattern is now the workspace-absolute
        # wildcard form (see the two tests below for why).
        upload_step = self._upload_step_text()
        self.assertIn(
            "path: ${{ github.workspace }}/apps/windows/rc003/dist/release/*",
            upload_step,
        )
        self.assertNotIn("dist/portable/*.zip", upload_step)
        self.assertNotIn("dist/installer/*.exe", upload_step)
        self.assertNotIn("dist/SHA256SUMS.txt", upload_step)
        # Exactly one "path:" input line, and it is a single scalar pattern
        # - never a YAML block/flow list of multiple patterns.
        self.assertEqual(upload_step.count("path:"), 1)
        self.assertNotIn("path: |", upload_step)
        self.assertNotIn("path:\n", upload_step)

    def test_release_dir_is_workspace_absolute_not_working_directory_relative(self):
        # XRBM-025 red evidence: run 29643870781's upload-artifact@v7 step
        # failed "No files were found with the provided path:
        # apps/windows/rc003/dist/release" - a working-directory-relative
        # producer path ($releaseDir = "dist/release", resolved against
        # the job's `apps/windows/rc003` defaults.run.working-directory)
        # and the upload step's own relative path input carry no
        # guarantee of resolving to the same directory. $releaseDir must
        # now be anchored on $env:GITHUB_WORKSPACE so packaging/preflight
        # always operate on an explicit absolute directory, removing that
        # ambiguity.
        step = self._package_step_text()
        self.assertIn("$env:GITHUB_WORKSPACE", step)
        self.assertNotIn('$releaseDir = "dist/release"', step)

    def test_producer_and_consumer_resolve_the_same_absolute_release_directory(self):
        # Proves equivalence, not just that each string exists in
        # isolation: the pwsh producer ($releaseDir) and the YAML consumer
        # (upload-artifact `path:`) must both be built from the SAME
        # workspace-root variable (`$env:GITHUB_WORKSPACE` and
        # `${{ github.workspace }}` are GitHub Actions' own two spellings
        # of the identical absolute value) joined with the identical
        # repository-relative suffix "apps/windows/rc003/dist/release" -
        # so producer and consumer can never again silently diverge the
        # way the relative forms did in run 29643870781.
        package_step = self._package_step_text()
        upload_step = self._upload_step_text()
        release_suffix = "apps/windows/rc003/dist/release"
        self.assertIn(
            "$env:GITHUB_WORKSPACE/" + release_suffix, package_step
        )
        self.assertIn(
            "${{ github.workspace }}/" + release_suffix + "/*", upload_step
        )

    def test_does_not_falsely_claim_zero_sendinput_or_raw_input_usage(self):
        # XRBM-022: the prior comment falsely claimed the job "does not
        # inject any SendInput/Raw Input event" - the Windows-only tests
        # under tests/windows/ actually do exercise a real, harmless,
        # runner-local SendInput call and Raw Input listener lifecycle.
        lower = self.text.lower()
        self.assertNotIn("does not inject any sendinput", lower)
        self.assertIn("sendinput", lower)
        self.assertIn("raw input", lower)

    def test_disclosure_still_denies_real_hardware_and_installer_execution(self):
        lower = self.text.lower()
        self.assertIn("no rc003", lower)
        self.assertIn("device attached", lower)
        self.assertIn("run the compiled installer", lower)

    def test_fetches_and_verifies_vb_cable_before_pyinstaller_build(self):
        # XRBM-031 In-scope item 8: a required gate, run BEFORE PyInstaller,
        # so the frozen build deterministically bundles the verified ZIP.
        self.assertIn("fetch-vb-cable.ps1", self.text)
        fetch_index = self.text.index("fetch-vb-cable.ps1")
        pyinstaller_index = self.text.index("PyInstaller build (unsigned candidate)")
        self.assertLess(fetch_index, pyinstaller_index)

    def test_vb_cable_fetch_step_is_a_required_gate_not_best_effort(self):
        step_start = self.text.index("- name: Fetch and verify VB-CABLE driver pack")
        next_step_start = self.text.index("- name:", step_start + 1)
        step_text = self.text[step_start:next_step_start]
        self.assertNotIn("continue-on-error", step_text)
        self.assertIn("$LASTEXITCODE", step_text)


class BuildCandidateScriptTests(unittest.TestCase):
    def setUp(self):
        self.text = _BUILD_CANDIDATE_PATH.read_text(encoding="utf-8")

    def test_test_suite_invocation_is_gated_by_resource_warning(self):
        # XRBM-022 controller pre-review correction: build-candidate.ps1
        # must enforce the same -W error::ResourceWarning policy as the CI
        # workflow's test-suite step, not just document it in prose.
        self.assertIn("-W error::ResourceWarning -m unittest discover", self.text)

    def test_fetches_and_verifies_vb_cable_before_pyinstaller_build(self):
        # XRBM-031 In-scope item 8: same ordering requirement as the CI
        # workflow (see WindowsCiWorkflowTests above) for the local build.
        self.assertIn("fetch-vb-cable.ps1", self.text)
        fetch_index = self.text.index("fetch-vb-cable.ps1")
        pyinstaller_index = self.text.index("PyInstaller build (unsigned candidate)")
        self.assertLess(fetch_index, pyinstaller_index)
        assert_index = self.text.index('Assert-LastExitCode "fetch-vb-cable.ps1"')
        self.assertGreater(assert_index, fetch_index)

    def test_windowed_executable_smoke_check_waits_for_real_exit_code(self):
        self.assertIn("Start-Process -FilePath $builtExe", self.text)
        self.assertIn("-WindowStyle Hidden -Wait -PassThru", self.text)
        self.assertIn("$smokeProcess.ExitCode", self.text)


class VbCablePinConsistencyTests(unittest.TestCase):
    """XRBM-031: the URL/SHA-256 pin must agree, character for character,
    across every place it is duplicated - the build-time fetch script
    (PowerShell) and the runtime verification module (Python) - so a future
    edit to one can never silently drift from the other the way the Frida
    Gadget pin's own two copies (fetch-frida-gadget.ps1 / frida_compat.py)
    already established as this project's precedent for this exact
    duplication pattern.
    """

    def setUp(self):
        self.fetch_script_text = (
            _RC003_ROOT / "build" / "fetch-vb-cable.ps1"
        ).read_text(encoding="utf-8")
        self.module_text = (
            _RC003_ROOT / "src" / "ovb_rc003" / "vb_cable_bundle.py"
        ).read_text(encoding="utf-8")

    def test_pinned_sha256_matches_between_ps1_and_py(self):
        from ovb_rc003 import vb_cable_bundle

        self.assertIn(
            vb_cable_bundle.VB_CABLE_PACK45.sha256.upper(), self.fetch_script_text
        )

    def test_pinned_url_matches_between_ps1_and_py(self):
        from ovb_rc003 import vb_cable_bundle

        self.assertIn(vb_cable_bundle.VB_CABLE_PACK45.url, self.fetch_script_text)
        self.assertIn(vb_cable_bundle.VB_CABLE_PACK45.url, self.module_text)

    def test_fetch_script_writes_to_gitignored_third_party_directory(self):
        self.assertIn("third_party", self.fetch_script_text)

    def test_fetch_script_fails_closed_on_hash_mismatch(self):
        self.assertIn("SHA-256 mismatch", self.fetch_script_text)
        self.assertIn("throw", self.fetch_script_text)


class UserFacingDocumentationContractTests(unittest.TestCase):
    """XRBM-022 controller pre-review correction: structural checks that the
    public README and the installed readme both actually contain the exact
    facts/URLs/commands the task book requires, not just prose that a human
    reviewer has to re-verify by eye every round.
    """

    def setUp(self):
        self.readme_text = _README_PATH.read_text(encoding="utf-8")
        self.installed_readme_text = _INSTALLED_README_PATH.read_text(encoding="utf-8")
        self.both = (self.readme_text, self.installed_readme_text)

    def test_official_vbcable_url_is_present_in_both_docs(self):
        for text in self.both:
            self.assertIn("https://vb-audio.com/Cable/", text)

    def test_checksum_verification_command_is_present_in_both_docs(self):
        for text in self.both:
            self.assertIn("Get-FileHash", text)
            self.assertIn("SHA256", text)
            self.assertIn("SHA256SUMS.txt", text)

    def test_exact_cable_routing_direction_is_preserved_in_both_docs(self):
        for text in self.both:
            self.assertIn("CABLE Input", text)
            self.assertIn("CABLE Output", text)
        # The direction itself, not just the two names in any order:
        # the bridge's own voice-output setting selects CABLE Input, and
        # the recognizer/system microphone input selects CABLE Output.
        self.assertIn("语音输出设备", self.readme_text)
        self.assertIn("CABLE Input", self.readme_text.split("语音输出设备")[1][:80])
        self.assertIn("语音输出设备", self.installed_readme_text)
        self.assertIn(
            "CABLE Input", self.installed_readme_text.split("语音输出设备")[1][:120]
        )

    def test_win_h_prerequisites_are_concrete_in_both_docs(self):
        for text in self.both:
            # Cursor focused in an editable field.
            self.assertIn("可编辑", text)
            # Manual Win+H test in Notepad (or another editable field)
            # BEFORE testing the RC003 itself.
            self.assertIn("记事本", text)
            self.assertIn("手动", text)
            # Windows' own online/networked speech-recognition setting.
            self.assertIn("联机语音识别", text)
            # The system/recognizer microphone input must be CABLE Output.
            self.assertIn("CABLE Output", text)

    def test_win_h_settings_path_is_given_for_both_windows_10_and_11(self):
        # XRBM-022 controller pre-review correction: the docs claim Windows
        # 10 1809+ support, but "设置 → 隐私和安全性 → 语音" is the Windows
        # 11 Settings path only - Windows 10's equivalent page is under
        # "设置 → 隐私 → 语音" instead. Both families must be named
        # explicitly so a Windows 10 user isn't sent looking for a menu
        # that doesn't exist on their system.
        for text in self.both:
            self.assertIn("Windows 11", text)
            self.assertIn("设置 → 隐私和安全性 → 语音", text)
            self.assertIn("Windows 10", text)
            self.assertIn("设置 → 隐私 → 语音", text)

    def test_thirteen_button_no_mute_key_and_back_gap_facts_are_present(self):
        for text in self.both:
            self.assertIn("13", text)
            self.assertIn("没有独立的物理静音键", text)
            self.assertIn("返回", text)


class RootDocumentConsistencyTests(unittest.TestCase):
    """XRBM-022 controller pre-review correction (third round): two public
    root documents contradicted the RC003 Windows candidate's own
    documentation. Both contradictions are fixed structurally here so they
    cannot silently return.
    """

    def setUp(self):
        self.root_readme_text = _ROOT_README_PATH.read_text(encoding="utf-8")
        self.notices_text = _THIRD_PARTY_NOTICES_PATH.read_text(encoding="utf-8")

    def test_root_readme_does_not_lump_windows_in_with_planned_research(self):
        self.assertIn("Windows 版本（RC003）", self.root_readme_text)
        self.assertIn("Windows 客户端位于", self.root_readme_text)
        self.assertIn("源码/构建候选", self.root_readme_text)
        self.assertIn("不能替代", self.root_readme_text)

    def test_third_party_notices_does_not_falsely_deny_all_vbcable_reference(self):
        # THIRD_PARTY_NOTICES.md previously claimed the Windows candidate
        # does not "reference VB-CABLE ... in any form" - false:
        # apps/windows/rc003/README.md and installer/readme-rc003.txt both
        # document the official VB-Audio VB-CABLE download as an optional
        # endpoint, and (XRBM-031) the frozen build now bundles the
        # official, verified, unmodified Basic package offline for a
        # user-initiated, UAC-gated install. The accurate claim: not
        # modified/re-licensed/silently installed by this project, and the
        # runtime only ever writes to an explicitly user-selected endpoint.
        self.assertNotIn(
            "does not download, install, configure, or reference VB-CABLE",
            self.notices_text,
        )
        self.assertNotIn(
            "does not bundle, download, install, configure, license, or redistribute VB-CABLE",
            self.notices_text,
        )
        self.assertIn("Donationware", self.notices_text)
        self.assertIn("explicitly selected", self.notices_text)

    def test_third_party_notices_discloses_the_bundled_vb_cable_flow_honestly(self):
        # XRBM-031: the notice must disclose that the official Basic package
        # is now bundled/fetched (not merely mentioned as a link), that only
        # the free Basic package (never paid A+B/C+D) is involved, that
        # installation only happens via an explicit user click plus a real
        # UAC prompt, and that this project's own process never runs
        # elevated and never reports install success from launch alone.
        self.assertIn("fetch-vb-cable.ps1", self.notices_text)
        self.assertIn("VBCABLE_Driver_Pack45.zip", self.notices_text)
        self.assertIn("A+B/C+D", self.notices_text)
        self.assertIn("UAC", self.notices_text)
        self.assertIn("never runs with administrator privileges", self.notices_text)
        self.assertIn(
            "never reports a driver install as successful merely because a process was launched",
            self.notices_text,
        )
        self.assertIn("never changes the Windows system default input/output device", self.notices_text)

    def test_root_readme_and_windows_readme_agree_rc003_windows_is_a_candidate(self):
        # Cross-file consistency: both docs must describe the RC003 Windows
        # combination the same way (source/build candidate, not
        # real-device verified) rather than one calling it a candidate and
        # the other calling it merely planned/research.
        windows_readme_text = _README_PATH.read_text(encoding="utf-8")
        for text in (self.root_readme_text, windows_readme_text):
            self.assertIn("源码/构建候选", text)


_CJK_CHAR_RE = r"[　-〿぀-ヿ㐀-鿿＀-￯]"


def _normalize_whitespace(text: str) -> str:
    """Strips markdown blockquote '>' line markers, then collapses all
    remaining whitespace (including the line wraps themselves, which are
    visually joined into flowing prose but stored as physical newlines)
    into single spaces - so a contract test can assert a multi-word phrase
    without depending on exactly where a human editor happened to wrap a
    line, or on the literal '>' markers those wrapped lines carry.

    Unlike English, a CJK line wrap carries no real space in the source
    author's intended reading (Chinese text has no inter-word spaces at
    all), so a whitespace run sitting between two CJK characters is
    dropped entirely rather than collapsed to a single space - otherwise a
    phrase like "出来的文件夹" that happens to wrap between "出来" and "的"
    would normalize to "出来 的文件夹" and silently fail an exact-phrase
    assertion that has nothing to do with the wrap point chosen.
    """

    text = re.sub(r"(?m)^>\s?", "", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(rf"(?<={_CJK_CHAR_RE}) (?={_CJK_CHAR_RE})", "", text)
    return text.strip()


class PrereleaseDownloadInstructionsContractTests(unittest.TestCase):
    """XRBM-027: the public prerelease download flow - a generic Releases
    page link (so it survives a tag not existing yet), the exact asset name
    patterns the CI packaging step actually produces, and the release-tag
    vs internal-build-version distinction - must stay documented and must
    not silently drift from what the CI workflow actually names its
    outputs (see WindowsCiWorkflowTests above for that side of the
    contract).
    """

    def setUp(self):
        self.text = _README_PATH.read_text(encoding="utf-8")
        self.iss_text = _ISS_PATH.read_text(encoding="utf-8")

    def test_links_to_the_generic_releases_page(self):
        self.assertIn(
            "https://github.com/miaomiaozii/windows-remote-mic-app/releases", self.text
        )
        # The bare list page is the stable entry point; any direct
        # /releases/tag/... link must point at a tag this repo actually
        # published (so a future tag bump that forgets to publish 404s the
        # doc instead of silently breaking).
        self.assertIn(
            "/releases/tag/v0.1.0-windows-rc003-candidate.1", self.text
        )

    def test_does_not_make_a_time_dependent_claim_about_prerelease_existence(self):
        # XRBM-027 RETRY 1 correction: a sentence saying "even if there is
        # currently no published prerelease yet" is temporally awkward and
        # goes stale the moment the first prerelease is published. The
        # Releases list must be described as a stable entry point without
        # asserting anything about whether a prerelease currently exists.
        self.assertNotIn("还没有发布任何预发行版", self.text)
        self.assertNotIn("发布后再回来查看", self.text)

    def test_asset_name_patterns_match_the_ci_workflows_actual_output_names(self):
        # These placeholders must match, character for character, the
        # deterministic names windows-rc003-ci.yml's packaging step
        # actually produces - see
        # WindowsCiWorkflowTests.test_packages_deterministic_zip_and_sha256sums
        # and .test_portable_staging_directory_is_a_single_versioned_top_level_folder
        # above, and the .iss OutputBaseFilename below.
        self.assertIn("RemoteMicRC003Setup-<版本号>-unsigned.exe", self.text)
        self.assertIn(
            "RemoteMicRC003-<版本号>-portable-unsigned.zip", self.text
        )
        self.assertIn("SHA256SUMS.txt", self.text)
        self.assertIn(
            "OutputBaseFilename=RemoteMicRC003Setup-{#AppVersion}-unsigned",
            self.iss_text,
        )

    def test_documents_the_release_tag_vs_internal_build_version_distinction(self):
        self.assertIn("v0.3.0-windows-rc003-candidate.1", self.text)
        # The doc's claimed internal build version must match the .iss
        # file's real AppVersion - not just a hardcoded literal that could
        # silently drift the moment a future task bumps AppVersion without
        # updating this sentence.
        version_match = re.search(r'#define AppVersion "([^"]+)"', self.iss_text)
        self.assertIsNotNone(version_match)
        self.assertIn(version_match.group(1), self.text)

    def test_installer_and_portable_are_documented_as_either_or_not_both(self):
        self.assertIn("不需要两个都下载", self.text)


class RealWindowsCiEvidenceContractTests(unittest.TestCase):
    """The Windows README must state capabilities and verification limits
    without copying a stale result from the upstream repository.
    """

    def setUp(self):
        self.readme_text = _normalize_whitespace(
            _README_PATH.read_text(encoding="utf-8")
        )

    def test_documents_supported_windows_paths(self):
        for phrase in ("WinRT BLE", "Raw Input", "SendInput", "PortAudio"):
            self.assertIn(phrase, self.readme_text)

    def test_status_is_a_candidate_that_has_passed_real_device_acceptance(self):
        # The candidate has since completed real-device acceptance (key-by-key
        # and voice-link); the README must say so honestly, while keeping the
        # "cannot be replaced by CI" limit.
        self.assertIn("源码/构建候选", self.readme_text)
        self.assertIn("已通过真实硬件验收", self.readme_text)
        self.assertIn("不能替代真机配对、按键和语音链路验收", self.readme_text)
        self.assertNotIn("verified on real rc003 hardware", self.readme_text.lower())

    def test_unsigned_and_ci_limits_are_documented(self):
        self.assertIn("未签名", self.readme_text)
        self.assertIn("CI 没有真实 RC003 硬件", self.readme_text)
        self.assertIn("已通过真实硬件验收", self.readme_text)

    def test_repository_links_to_its_own_actions_and_releases(self):
        self.assertIn("https://github.com/miaomiaozii/windows-remote-mic-app/releases", self.readme_text)
        self.assertIn("https://github.com/miaomiaozii/windows-remote-mic-app/actions", self.readme_text)


class PortableAndInstallerFlowContractTests(unittest.TestCase):
    """XRBM-027 RETRY 1 correction: the installer and the portable ZIP are
    materially different distributions - the portable ZIP has no Start
    Menu entries, no stop script, and no uninstaller, so it must never be
    told to a user via the installer's Start Menu instructions. Each flow
    needs its own settings/start/stop/removal steps, and the portable
    steps must name the real executable and real flags this candidate
    actually ships (see __main__.py's ``--settings``/no-argument handling
    and the .spec's ``AppExeName``/``RemoteMicRC003.exe``).
    """

    def setUp(self):
        self.text = _README_PATH.read_text(encoding="utf-8")
        self.normalized = _normalize_whitespace(self.text)

    def test_portable_settings_command_is_exact(self):
        self.assertIn(
            r".\RemoteMicRC003.exe --settings", self.text
        )

    def test_portable_start_command_uses_the_explicit_bridge_flag(self):
        # The no-argument invocation now opens the settings window, so the
        # bridge must be started explicitly with --bridge - paired with
        # prose that says it starts the bridge itself.
        self.assertIn(
            r"`.\RemoteMicRC003.exe --bridge` 启动桥接", self.normalized
        )

    def test_portable_stop_is_via_task_manager_not_a_stop_script(self):
        self.assertIn("任务管理器", self.text)
        self.assertIn("结束任务", self.text)
        self.assertIn("Ctrl+Shift+Esc", self.text)
        # Must explicitly say there is no packaged stop script/Start Menu
        # entry for the portable flow, so this isn't confused with the
        # installer's "停止" Start Menu shortcut.
        self.assertIn("便携版没有停止脚本", self.normalized)

    def test_portable_removal_is_deleting_the_extracted_folder(self):
        self.assertIn("删除整个解压出来的文件夹", self.normalized)
        self.assertIn("便携版没有安装程序", self.normalized)

    def test_installer_flow_still_retains_start_menu_settings_start_stop_uninstall(self):
        installer_section_start = self.text.index("方式一：安装器")
        installer_section_end = self.text.index("方式二：便携版")
        installer_section = self.text[installer_section_start:installer_section_end]
        for entry in ("设置", "启动", "停止", "卸载"):
            self.assertIn(entry, installer_section)
        self.assertIn("Start Menu", installer_section)

    def test_portable_flow_explicitly_denies_start_menu_entries(self):
        portable_section_start = self.text.index("方式二：便携版")
        portable_section_end = self.text.index("### 配对 RC003")
        portable_section = self.text[portable_section_start:portable_section_end]
        self.assertIn("没有", portable_section)
        self.assertIn("Start Menu", portable_section)

    def test_installer_and_portable_steps_are_documented_in_separate_subsections(self):
        self.assertIn("**安装器用户**", self.text)
        self.assertIn("**便携版 ZIP 用户**", self.text)
        installer_index = self.text.index("**安装器用户**")
        portable_index = self.text.index("**便携版 ZIP 用户**")
        self.assertLess(installer_index, portable_index)


class ConfigLogResidueDisclosureContractTests(unittest.TestCase):
    """XRBM-027 CORRECTION 1: neither uninstalling via the installer nor
    deleting the portable ZIP's extracted folder removes the runtime
    settings/log files, because both write to the same
    ``config.config_root()`` location and the .iss source has no
    ``UninstallDelete`` rule for them. Both public docs must disclose this
    honestly, and the literal path/filename strings they use must be
    cross-checked against the real runtime constants so a future rename in
    config.py/logging_setup.py can't silently leave the docs wrong.
    """

    def setUp(self):
        self.readme_text = _normalize_whitespace(
            _README_PATH.read_text(encoding="utf-8")
        )
        self.installed_readme_text = _normalize_whitespace(
            _INSTALLED_README_PATH.read_text(encoding="utf-8")
        )
        self.both = (self.readme_text, self.installed_readme_text)
        self.iss_text = _ISS_PATH.read_text(encoding="utf-8")

    def test_documented_path_and_filenames_match_the_real_runtime_constants(self):
        # Not hardcoded literals independent of the source of truth: derive
        # the exact strings from config.py/logging_setup.py themselves, so
        # a future rename of APP_ID/PRODUCT_ID/CONFIG_FILENAME/
        # KEY_BINDINGS_FILENAME/LOG_FILENAME breaks this test instead of
        # silently leaving the docs pointing at a stale path/filename.
        expected_root = r"%LOCALAPPDATA%\{}\{}".format(
            config.APP_ID, config.PRODUCT_ID
        )
        for text in self.both:
            self.assertIn(expected_root, text)
            self.assertIn(config.CONFIG_FILENAME, text)
            self.assertIn(config.KEY_BINDINGS_FILENAME, text)
            self.assertIn(logging_setup.LOG_FILENAME, text)
            # The log file lives in a "logs" subdirectory of config_root(),
            # not directly inside it (see logging_setup.get_logger()).
            self.assertIn("logs" + "\\" + logging_setup.LOG_FILENAME, text)

    def test_iss_has_no_uninstall_delete_rule_for_runtime_files(self):
        # Regression guard for the premise both docs now rely on: if a
        # future change adds an [UninstallDelete] entry, that's a genuine
        # behavior change requiring its own runtime/installer-scoped task,
        # and this doc's "uninstall does not remove settings/logs" claim
        # would need to be revisited together with it - this test fails
        # first, loudly, instead of the docs silently going stale.
        self.assertNotIn("UninstallDelete", self.iss_text)

    def test_uninstall_does_not_claim_full_directory_removal(self):
        for text in self.both:
            self.assertNotIn("不留系统级文件", text)
        # The installed readme previously claimed uninstall deletes "安装
        # 目录" (the whole install directory) outright - inaccurate, since
        # config_root() is the SAME directory the installer uses
        # (DefaultDirName={localappdata}\RemoteMic\{#AppFolder}) and
        # runtime-written files there are never enumerated by Setup, so
        # Inno's uninstaller does not know to remove them.
        self.assertNotIn(
            "卸载过程会先自动停止正在运行的桥接进程，再删除安装目录",
            self.installed_readme_text,
        )

    def test_both_docs_disclose_settings_and_logs_survive_removal(self):
        for text in self.both:
            self.assertIn("卸载不会自动删除设置和日志", text)

    def test_both_docs_offer_conditional_manual_cleanup(self):
        # Must be conditional (only when no other RC003 install on the same
        # machine needs the shared directory) - not an unconditional "just
        # delete it" instruction, since the installer and portable builds
        # share the exact same config_root() on one machine.
        for text in self.both:
            self.assertIn("如果还会用到", text)
            self.assertIn("请不要删除这个共享目录", text)

    def test_portable_removal_step_names_config_root_not_just_the_extracted_folder(self):
        # The portable "uninstall/removal" step specifically must not stop
        # at "delete the extracted folder" - it must name the separate,
        # shared config_root() location too.
        portable_section_start = self.readme_text.index("**便携版 ZIP 用户**")
        portable_section = self.readme_text[portable_section_start:]
        self.assertIn("但便携版运行时同样会把", portable_section)
        self.assertIn(config.CONFIG_FILENAME, portable_section)


class WindowsPrereleaseAssetScopeContractTests(unittest.TestCase):
    """XRBM-027 CORRECTION 1: a bare "every prerelease has exactly these
    three files" claim must not be read as covering unrelated releases or
    other product variants.
    """

    def setUp(self):
        self.text = _README_PATH.read_text(encoding="utf-8")

    def test_asset_count_claim_is_scoped_to_the_windows_candidate(self):
        self.assertIn("每个 RC003 Windows 候选预发行版恰好包含以下三个文件", self.text)
        self.assertNotIn("每个预发行版恰好包含以下三个文件", self.text)


def _spec_hidden_imports(text: str) -> list:
    tree = ast.parse(text, filename=str(_SPEC_PATH))
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "hiddenimports"
            for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError("hiddenimports assignment not found in spec")


class QtSettingsUiSpecTests(unittest.TestCase):
    """XRBM-030: static contract that the PyInstaller spec actually bundles
    the Qt Quick/QML settings window's own qml/ sources (never covered by
    any PySide6 hook, which only auto-collects Qt's OWN Quick Controls/QML
    plugin assets - see the spec's own comment) and hidden-imports every
    PySide6 submodule qt_settings_app.py needs - a real Windows CI
    PyInstaller build remains the platform-level confirmation on top of
    this structural one.
    """

    def setUp(self):
        self.spec_text = _SPEC_PATH.read_text(encoding="utf-8")
        self.requirements_text = _REQUIREMENTS_PATH.read_text(encoding="utf-8")

    def test_requirements_pins_pyside6_essentials(self):
        self.assertIn("PySide6-Essentials==", self.requirements_text)
        # Never an actual PySide6-Addons *pin* - checked against effective
        # (non-comment) content, since requirements.txt's own comment
        # legitimately explains in prose why Addons is excluded.
        self.assertNotIn(
            "PySide6-Addons", _strip_hash_comments(self.requirements_text)
        )

    def test_spec_collects_the_qml_source_tree_as_data_under_the_expected_name(self):
        # Must match qt_settings_app.py's _qml_directory() frozen-build
        # lookup path exactly: sys._MEIPASS / "ovb_rc003_qml".
        self.assertIn('QML_SOURCE_DIR = SRC_ROOT / "ovb_rc003" / "qml"', self.spec_text)
        self.assertIn('datas.append((str(QML_SOURCE_DIR), "ovb_rc003_qml"))', self.spec_text)

    def test_spec_hidden_imports_every_pyside6_submodule_qt_settings_app_uses(self):
        hiddenimports = _spec_hidden_imports(self.spec_text)
        for module in (
            "PySide6.QtCore",
            "PySide6.QtGui",
            "PySide6.QtQml",
            "PySide6.QtQuick",
            "PySide6.QtQuickControls2",
            "ovb_rc003.qt_settings_app",
        ):
            self.assertIn(module, hiddenimports)

    def test_qml_directory_name_matches_qt_settings_app_frozen_lookup(self):
        # Cross-file consistency: the exact "ovb_rc003_qml" folder name must
        # agree between the spec (producer) and qt_settings_app.py's
        # _qml_directory() (consumer) - a silent rename on either side would
        # otherwise pass every other test here and only fail at runtime on a
        # real frozen build, the same class of bug XRBM-024's WinRT
        # dependency-closure tests above guard against.
        qt_settings_app_path = (
            _RC003_ROOT / "src" / "ovb_rc003" / "qt_settings_app.py"
        )
        qt_settings_app_text = qt_settings_app_path.read_text(encoding="utf-8")
        self.assertIn('"ovb_rc003_qml"', self.spec_text)
        self.assertIn('"ovb_rc003_qml"', qt_settings_app_text)


if __name__ == "__main__":
    unittest.main()
