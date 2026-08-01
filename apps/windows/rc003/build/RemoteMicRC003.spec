"""PyInstaller one-dir build for the independent Windows RC003 app."""

from pathlib import Path


RC003_ROOT = Path(SPECPATH).resolve().parent
SRC_ROOT = RC003_ROOT / "src"

hiddenimports = [
    "ovb_rc003.app",
    "ovb_rc003.atvv_protocol",
    "ovb_rc003.atvv_session",
    "ovb_rc003.audio_output",
    "ovb_rc003.audio_playback",
    "ovb_rc003.ble_transport_winrt",
    "ovb_rc003.config",
    "ovb_rc003.connection_supervisor",
    "ovb_rc003.device_profile",
    "ovb_rc003.identity",
    "ovb_rc003.settings_ui",
    "ovb_rc003.single_instance",
    "numpy",
    "sounddevice",
    "winrt.windows.devices.bluetooth",
    "winrt.windows.devices.bluetooth.genericattributeprofile",
    "winrt.windows.devices.enumeration",
    "winrt.windows.storage.streams",
    "winrt.windows.foundation",
    "winrt.windows.foundation.collections",
]

a = Analysis(
    [str(SRC_ROOT / "launcher.py")],
    pathex=[str(SRC_ROOT)],
    binaries=[],
    datas=[],
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["PySide6", "frida"],
    noarchive=False,
)

pyz = PYZ(a.pure)

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
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="RemoteMicRC003",
)
