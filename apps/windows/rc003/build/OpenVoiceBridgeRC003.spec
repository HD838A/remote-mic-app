# PyInstaller spec for Open Voice Bridge · RC003 (Windows source/build candidate).
#
# One-dir build (COLLECT), matching the layout pattern this project's
# upstream reference uses for its own standalone products, minus everything
# out of scope for this candidate: no VB-CABLE files, no Frida binary (never
# bundled - see ovb_rc003.frida_compat), no other-device (T1/V60) code, and
# no licensing/DRM modules (none exist in this tree to begin with).
#
# Build with (inside a Windows virtual environment with requirements-dev.txt
# installed):
#   pyinstaller build/OpenVoiceBridgeRC003.spec
#
# This produces an UNSIGNED candidate under dist/OpenVoiceBridgeRC003/. Real
# code signing is out of scope for this source/build candidate.

import sys
from pathlib import Path

block_cipher = None

RC003_ROOT = Path(SPECPATH).resolve().parent
SRC_ROOT = RC003_ROOT / "src"
REPO_ROOT = RC003_ROOT.parents[2]
REMOTE_PHOTO = REPO_ROOT / "Resources" / "RC003-remote-photo.png"

datas = []
if REMOTE_PHOTO.is_file():
    # Re-verified correct for this one-dir COLLECT build (XRBM-018 RETRY 1
    # P2 #4): this places the photo under Resources/ inside the COLLECT
    # output, which PyInstaller's bootloader exposes at runtime as
    # sys._MEIPASS/Resources/ - see ovb_rc003/resources.py's
    # find_remote_photo(), which checks that path first in a frozen build.
    datas.append((str(REMOTE_PHOTO), "Resources"))

hiddenimports = [
    "ovb_rc003.app",
    "ovb_rc003.settings_ui",
    "ovb_rc003.ble_transport_winrt",
    "ovb_rc003.raw_input_windows",
    "ovb_rc003.audio_playback",
    "ovb_rc003.win32_input",
    "ovb_rc003.connection_supervisor",
    "ovb_rc003.single_instance",  # XRBM-021: imported lazily inside
    # __main__.py's _run_bridge(), same as the other lazily-imported
    # modules above.
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
    name="OpenVoiceBridgeRC003",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name="OpenVoiceBridgeRC003",
)
