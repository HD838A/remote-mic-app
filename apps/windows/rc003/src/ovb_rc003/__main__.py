"""Remote Mic RC003 Windows 客户端入口。"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from . import __version__, audio_output, config, single_instance


def _configure_logging() -> logging.Logger:
    target = config.log_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("remote_mic_rc003")
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = logging.FileHandler(target, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s: %(message)s"))
        logger.addHandler(handler)
    return logger


async def _run_bridge_async() -> None:
    from .app import RC003VoiceBridge

    settings = config.load_config()
    if not settings["output_endpoint_name"]:
        raise config.ConfigError("尚未选择语音输出设备，请先打开设置")
    bridge = RC003VoiceBridge(settings, logger=_configure_logging())
    try:
        await bridge.run_forever()
    finally:
        await bridge.stop()


def _run_bridge() -> int:
    try:
        with single_instance.BridgeInstanceGuard():
            asyncio.run(_run_bridge_async())
        return 0
    except single_instance.DuplicateInstanceError as exc:
        single_instance.show_bridge_startup_blocked_notice(str(exc))
        return single_instance.DUPLICATE_INSTANCE_EXIT_CODE
    except single_instance.SingleInstanceUnavailableError as exc:
        single_instance.show_bridge_startup_blocked_notice(str(exc))
        return single_instance.GUARD_UNAVAILABLE_EXIT_CODE
    except single_instance.MutexCleanupError as exc:
        single_instance.show_bridge_startup_blocked_notice(str(exc))
        return single_instance.CLEANUP_FAILED_EXIT_CODE
    except Exception as exc:  # noqa: BLE001 - packaged app needs a visible failure
        single_instance.show_bridge_startup_blocked_notice(f"桥接启动失败：{exc}")
        return 1


def _list_output_devices() -> int:
    for endpoint in audio_output.enumerate_output_endpoints():
        print(f"{endpoint.name}\t{endpoint.host_api}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="RemoteMicRC003")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--bridge", action="store_true", help="启动 RC003 麦克风桥接")
    mode.add_argument("--settings", action="store_true", help="打开设置窗口")
    mode.add_argument("--list-output-devices", action="store_true", help="列出播放端点")
    mode.add_argument("--dry-run", action="store_true", help="仅验证模块可以导入")
    parser.add_argument("--version", action="version", version=__version__)
    args = parser.parse_args(argv)

    if args.dry_run:
        from . import app, atvv_protocol, atvv_session, audio_playback, ble_transport_winrt

        del app, atvv_protocol, atvv_session, audio_playback, ble_transport_winrt
        print("Remote Mic RC003 dry-run passed")
        return 0
    if args.list_output_devices:
        return _list_output_devices()
    if args.bridge:
        return _run_bridge()

    from .settings_ui import run_settings

    run_settings()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
