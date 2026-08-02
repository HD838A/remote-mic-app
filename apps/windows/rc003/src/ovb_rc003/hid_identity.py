"""RC003 Windows HID 路径匹配与 16 位 usage 报告解码。"""

from __future__ import annotations

from . import device_profile


def device_path_matches_rc003(device_interface_path: str) -> bool:
    """同时识别经典 HID 和 Windows BLE HID collection 路径。"""

    normalized = device_interface_path.casefold()
    classic = (
        f"vid_{device_profile.HID_VENDOR_ID:04x}" in normalized
        and f"pid_{device_profile.HID_PRODUCT_ID:04x}" in normalized
    )
    if classic:
        return True
    ble_vid_tokens = (
        f"dev_vid&{device_profile.HID_VENDOR_ID:06x}",
        f"dev_vid&01{device_profile.HID_VENDOR_ID:04x}",
    )
    return any(token in normalized for token in ble_vid_tokens) and (
        f"pid&{device_profile.HID_PRODUCT_ID:04x}" in normalized
    )


def decode_report_usages(report: bytes) -> frozenset[int]:
    """解析 RC003 的 3 个 little-endian uint16 usage 槽。"""

    if len(report) == 9 and report[:3] == b"\x01\x00\x00":
        payload = report[3:]
    elif len(report) == 7 and report[0] == 0x01:
        payload = report[1:]
    elif len(report) == 6:
        payload = report
    else:
        raise ValueError(f"不支持的 RC003 HID 报告长度：{len(report)}")
    usages = {
        int.from_bytes(payload[offset : offset + 2], "little")
        for offset in range(0, 6, 2)
    }
    usages.discard(0)
    return frozenset(usages)


def decode_active_buttons(report: bytes) -> frozenset[str]:
    return frozenset(
        device_profile.BUTTON_USAGE_IDS[usage]
        for usage in decode_report_usages(report)
        if usage in device_profile.BUTTON_USAGE_IDS
    )
