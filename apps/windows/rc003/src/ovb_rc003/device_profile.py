"""Static identity facts for the Xiaomi Bluetooth Remote 2 Pro / RC003.

Derived from ``device-profiles/xiaomi-rc003.json`` and kept consistent with the
Windows device profile so the client identifies the intended physical product.

Upstream provenance (GPL-3.0-only, informational only - no code copied):
xxb26553663-star/remote-bridge-hub @ 8a93f321ac71a602300c6cd77f7256fa4b63068e,
source/bridges/xiaomi/hid_report_tap.py and hid_tap_runtime.py (RC003 hardware
token "dev_vid&012717_pid&32b8_rev&00a4" confirms VID 0x2717 / PID 0x32B8).
"""

from __future__ import annotations

DISPLAY_NAME = "Xiaomi Bluetooth Remote 2 Pro / RC003"
VENDOR = "Xiaomi"
MODEL = "RC003"

# Bluetooth advertised/paired device names this client will match against.
# Matching is exact (case/whitespace-insensitive) - never a fuzzy substring -
# per the project rule against broad "Xiaomi" matching.
BLUETOOTH_NAMES = frozenset(
    {
        "mi rc",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
    }
)

HID_VENDOR_ID = 0x2717
HID_PRODUCT_ID = 0x32B8

# HID Keyboard-page (Usage Page 0x07) usage IDs the RC003 reports for its
# physical buttons. The microphone button is normally expected to be signaled
# over the ATVV GATT control channel, but real Windows RC003 hardware also
# reports it as Keyboard F5 (usage 0x003E), so it is included here as a
# host-trigger fallback. One button ("back") sits
# outside the standard translated usage range on Windows; see
# ovb_rc003.frida_compat for the documented, currently-unwired compatibility
# gap.
HID_USAGE_PAGE = 0x07

BUTTON_USAGE_IDS = {
    0x003E: "mic",
    0x00F1: "back",
    0x0028: "ok",
    0x0035: "tv",
    0x004A: "home",
    0x004F: "right",
    0x0050: "left",
    0x0051: "down",
    0x0052: "up",
    0x0065: "menu",
    0x0066: "power",
    0x007F: "volume_mute",
    0x0080: "volume_up",
    0x0081: "volume_down",
}

# All logical buttons this client knows about.
ALL_BUTTON_IDS = frozenset(set(BUTTON_USAGE_IDS.values()) | {"mic"})
