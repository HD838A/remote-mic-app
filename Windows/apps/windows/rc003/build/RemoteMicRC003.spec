# PyInstaller spec for Remote Mic · RC003 (Windows source/build candidate).
#
# One-dir build (COLLECT), matching the layout pattern this project's
# upstream reference uses for its own standalone products, minus everything
# out of scope for this candidate: no other-device (T1/V60) code, and no
# licensing/DRM modules (none exist in this tree to begin with). The optional,
# hash-verified Frida archive is bundled only when the explicit fetch step
# placed it in the source tree; it is never downloaded by this spec.
#
# Build with (inside a Windows virtual environment with requirements-dev.txt
# installed):
#   pyinstaller build/RemoteMicRC003.spec
#
# This produces an UNSIGNED candidate under dist/RemoteMicRC003/. Real
# code signing is out of scope for this source/build candidate.

import sys
from pathlib import Path

block_cipher = None

RC003_ROOT = Path(SPECPATH).resolve().parent
SRC_ROOT = RC003_ROOT / "src"
REPO_ROOT = RC003_ROOT.parents[2]
REMOTE_PHOTO = REPO_ROOT / "Resources" / "RC003-remote-photo.png"
APP_ICON = REPO_ROOT / "Resources" / "RemoteMic-AppIcon.ico"
QML_SOURCE_DIR = SRC_ROOT / "ovb_rc003" / "qml"
DEVICE_PROFILES_DIR = REPO_ROOT / "device-profiles"
# XRBM-031: build/fetch-vb-cable.ps1 (a REQUIRED step in both
# build-candidate.ps1 and windows-rc003-ci.yml, run before this spec) writes
# the hash-verified official VB-CABLE base package here. Bundled unmodified
# as application data (never re-verified/re-hashed at build time - only at
# RUNTIME, independently, by vb_cable_bundle.verify_bundle() before any
# extraction) so the frozen build's optional driver-helper page works fully
# offline on the end-user machine.
VB_CABLE_BUNDLE_ZIP = RC003_ROOT / "build" / "third_party" / "VBCABLE_Driver_Pack45.zip"
FRIDA_ASSET_DIR = SRC_ROOT / "ovb_rc003" / "frida_assets"

datas = []
if REMOTE_PHOTO.is_file():
    # Re-verified correct for this one-dir COLLECT build (XRBM-018 RETRY 1
    # P2 #4): this places the photo under Resources/ inside the COLLECT
    # output, which PyInstaller's bootloader exposes at runtime as
    # sys._MEIPASS/Resources/ - see ovb_rc003/resources.py's
    # find_remote_photo(), which checks that path first in a frozen build.
    datas.append((str(REMOTE_PHOTO), "Resources"))
if APP_ICON.is_file():
    datas.append((str(APP_ICON), "Resources"))
if QML_SOURCE_DIR.is_dir():
    # XRBM-030: the settings window's own QML sources (main.qml/Tokens.qml/
    # ConnectionPage.qml/ButtonsPage.qml/PermissionsPage.qml) are real files
    # on disk, not a Python module - PyInstaller's Analysis never discovers
    # them on its own, and no PySide6 hook bundles THIRD-PARTY qml/ trees
    # (only Qt's OWN Quick Controls/QML plugin assets, handled automatically
    # by PyInstaller's bundled PySide6 hooks). Collected under
    # "ovb_rc003_qml" inside the COLLECT output, matching
    # qt_settings_app.py's ``_qml_directory()``, which looks under
    # ``sys._MEIPASS / "ovb_rc003_qml"`` in a frozen build - same
    # sys._MEIPASS-relative reasoning as the photo above (see
    # resources.py's module docstring).
    datas.append((str(QML_SOURCE_DIR), "ovb_rc003_qml"))
if DEVICE_PROFILES_DIR.is_dir():
    # The exact repository JSON files are the runtime catalog for Windows. The
    # frozen loader reads them from
    # sys._MEIPASS/device-profiles and fails closed if they are absent or
    # invalid; no generated/hard-coded duplicate is bundled.
    datas.append((str(DEVICE_PROFILES_DIR), "device-profiles"))
if VB_CABLE_BUNDLE_ZIP.is_file():
    # Collected under "vb_cable_bundle" inside the COLLECT output, matching
    # vb_cable_bundle.py's _candidate_bundle_paths(), which looks under
    # sys._MEIPASS / "vb_cable_bundle" in a frozen build - same
    # sys._MEIPASS-relative reasoning as the photo/qml entries above. A
    # missing file here (e.g. a local `pyinstaller` invocation that skipped
    # fetch-vb-cable.ps1) is not a spec-time error - build-candidate.ps1 and
    # windows-rc003-ci.yml are what make fetching it a REQUIRED gate before
    # this spec ever runs for a real candidate build; this spec itself stays
    # defensive/optional, matching the existing photo/qml pattern above.
    datas.append((str(VB_CABLE_BUNDLE_ZIP), "vb_cable_bundle"))
for frida_asset in FRIDA_ASSET_DIR.glob("*.xz"):
    # Runtime verifies the archive again before extracting it into the locked
    # ProgramData directory. This remains optional for source-only builds.
    datas.append((str(frida_asset), "ovb_rc003/frida_assets"))

hiddenimports = [
    "ovb_rc003.app",
    "ovb_rc003.device_catalog",  # XRBM-036: multi-device settings/runtime gate
    "ovb_rc003.settings_ui",
    "ovb_rc003.qt_settings_app",  # XRBM-030
    "ovb_rc003.windows_diagnostics",  # XRBM-031
    "ovb_rc003.vb_cable_bundle",  # XRBM-031
    "ovb_rc003.ble_transport_winrt",
    "ovb_rc003.raw_input_windows",
    "ovb_rc003.audio_playback",
    "ovb_rc003.win32_input",
    "ovb_rc003.connection_supervisor",
    "ovb_rc003.doubao_rpc",
    "ovb_rc003.frida_compat",
    "ovb_rc003.frida_hid_tap_runtime",
    "ovb_rc003.frida_hid_tap_injector",
    "ovb_rc003.single_instance",  # XRBM-021: imported lazily inside
    # __main__.py's _run_bridge(), same as the other lazily-imported
    # modules above.
    "frida",
    # Optional runtime dependencies, imported lazily inside functions in
    # audio_output.py/audio_playback.py/ble_transport_winrt.py, which
    # PyInstaller's static analysis cannot always auto-detect:
    "sounddevice",
    "numpy",
    "winrt.windows.devices.bluetooth",
    "winrt.windows.devices.bluetooth.genericattributeprofile",
    "winrt.windows.devices.enumeration",
    "winrt.windows.storage.streams",
    # XRBM-024: find_all_async_aqs_filter()'s returned IAsyncOperation and
    # DeviceInformationCollection's iterator both come from these two
    # projections at runtime (see requirements.txt's XRBM-024 comment) -
    # PyInstaller's static analysis cannot see that dependency because
    # ble_transport_winrt.py never imports these modules by name, so they
    # must be listed explicitly or the frozen build passes analysis and
    # then crashes on first real BLE discovery.
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
    # XRBM-030: qt_settings_app.py imports these lazily inside a function
    # body (so importing the module itself never requires PySide6 - see its
    # docstring), which PyInstaller's static import-graph analysis follows
    # regardless of the surrounding try/except, but listed explicitly here
    # too since QtQuickControls2/the FluentWinUI3 style module in
    # particular is loaded through Qt's own plugin system rather than a
    # plain Python import graph PyInstaller can always trace.
    "PySide6.QtCore",
    "PySide6.QtGui",
    "PySide6.QtQml",
    "PySide6.QtQuick",
    "PySide6.QtQuickControls2",
]

a = Analysis(
    # XRBM-021: analyze the standalone src/launcher.py, NOT the package's
    # own src/ovb_rc003/__main__.py. PyInstaller treats its entry script as
    # a top-level module with no parent package, so __main__.py's
    # package-relative imports (correct for `python -m ovb_rc003`) raised
    # "attempted relative import with no known parent package" the moment
    # the previously-built frozen executable actually ran - see the red
    # baseline in the XRBM-021 task book and
    # tests/test_build_artifacts.py::LauncherEntryPointTests. launcher.py
    # instead does one absolute import (`from ovb_rc003.__main__ import
    # main`), which needs no parent package.
    [str(SRC_ROOT / "launcher.py")],
    pathex=[str(SRC_ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Defensive: this tree never contains these, but excluding them keeps
        # the boundary explicit if the spec is ever copy-pasted elsewhere.
        "bridges.t1",
        "bridges.hanvon",
        "licensing",
        "customer_license",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="RemoteMicRC003",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    icon=str(APP_ICON),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name="RemoteMicRC003",
)
