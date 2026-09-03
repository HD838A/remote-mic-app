"""Command-line RC003 physical-key capture and adaptation tool.

Examples (run from ``apps/windows/rc003`` with ``PYTHONPATH=src``):

    python src/rc003_key_test.py capture --assign back
    python src/rc003_key_test.py replay --input path/to/capture.jsonl --button back

Capture never executes a configured action. ``--assign`` writes only the
portable physical signature mapping; the normal semantic action mapping is
still responsible for deciding what ``back`` does.
"""

from __future__ import annotations

import argparse
import threading
import time
from pathlib import Path
from typing import List, Optional, Sequence

from ovb_rc003 import config, device_profile, hid_identity, key_testing
from ovb_rc003 import raw_input_windows


_GUIDED_BUTTONS = ("back", "volume_up", "volume_down")
_GUIDED_LABELS = {
    "back": "返回键",
    "volume_up": "音量+键",
    "volume_down": "音量-键",
}


def _button_id(value: str) -> str:
    if value not in device_profile.ALL_BUTTON_IDS:
        choices = ", ".join(device_profile.ALL_BUTTON_IDS)
        raise argparse.ArgumentTypeError(
            f"unknown RC003 button {value!r}; choose one of: {choices}"
        )
    return value


def _default_capture_path() -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return config.config_root() / "captures" / f"rc003-{stamp}.jsonl"


def _capture(args: argparse.Namespace) -> int:
    try:
        paths = raw_input_windows.enumerate_matching_device_paths()
        device_path = hid_identity.select_single_device_path(paths)
    except Exception as exc:  # noqa: BLE001 - CLI must report the hardware failure
        print(f"cannot select one RC003 HID device: {exc}")
        return 2

    recorder = key_testing.KeyCaptureRecorder()
    first_signature: List[str] = []
    finished = threading.Event()

    def on_raw_event(event: raw_input_windows.RawInputEvent) -> None:
        recorder.append(event)
        if event.decode_error:
            print(f"decode error: {event.decode_error}")
            return
        signature = raw_input_windows.physical_signature(event)
        edge = "down" if event.is_pressed else "up"
        print(
            f"{edge}: button={event.button_id or 'unknown'} "
            f"signature={signature}"
        )
        if event.is_pressed and not first_signature:
            first_signature.append(signature)
        elif not event.is_pressed and first_signature and signature == first_signature[0]:
            finished.set()

    listener = raw_input_windows.RawInputButtonListener(lambda *_: None, on_raw_event)
    try:
        listener.start(device_path)
        print(
            f"listening for one RC003 press/release for up to {args.duration:g}s; "
            "no configured action will run"
        )
        finished.wait(timeout=args.duration)
    except Exception as exc:  # noqa: BLE001 - CLI must report the hardware failure
        print(f"capture failed: {exc}")
        return 2
    finally:
        try:
            listener.stop()
        except Exception as exc:  # noqa: BLE001 - preserve the capture for diagnosis
            print(f"listener stop failed: {exc}")

    events = recorder.events()
    output = Path(args.output) if args.output else _default_capture_path()
    recorder.write_jsonl(output)
    print(f"capture written: {output}")
    if not events or not first_signature or not finished.is_set():
        print("no complete physical key press/release was captured")
        return 1

    bindings = {}
    if args.assign:
        first_press = next(event for event in events if event.is_pressed)
        bindings = key_testing.binding_for_event(first_press, args.assign)

    expected = args.assign or args.expected
    if expected:
        result = key_testing.evaluate_key_capture(
            events, expected, physical_bindings=bindings
        )
        print(
            f"test {'PASS' if result.passed else 'FAIL'}: expected={expected} "
            f"press={result.saw_press} release={result.saw_release}"
        )
        for error in result.decode_errors:
            print(f"decode error: {error}")
        if not result.passed:
            return 1
        if args.assign:
            _save_physical_binding(bindings)
            print(f"physical binding saved: {first_signature[0]} -> {args.assign}")
        return 0 if result.passed else 1
    print(f"captured signature: {first_signature[0]}")
    return 0


def _save_physical_binding(binding) -> None:
    path = config.key_bindings_path(config.config_root())
    bindings = config.load_key_bindings(path)
    physical = bindings.setdefault("physical_bindings", {})
    physical.update(binding)
    config.save_key_bindings(path, bindings)


def _guided_capture_path(button: str) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return config.config_root() / "captures" / f"rc003-guided-{stamp}-{button}.jsonl"


def _capture_guided_key(
    device_path: str, button: str, duration: float
) -> bool:
    recorder = key_testing.KeyCaptureRecorder()
    first_signature: List[str] = []
    decode_errors: List[str] = []
    finished = threading.Event()

    def on_raw_event(event: raw_input_windows.RawInputEvent) -> None:
        recorder.append(event)
        if event.decode_error:
            if event.decode_error not in decode_errors:
                decode_errors.append(event.decode_error)
            return
        if finished.is_set():
            return
        signature = raw_input_windows.physical_signature(event)
        if event.is_pressed and not first_signature:
            first_signature.append(signature)
            print("  已收到按下，请现在松开", flush=True)
        elif (
            not event.is_pressed
            and first_signature
            and signature == first_signature[0]
        ):
            finished.set()

    listener = raw_input_windows.RawInputButtonListener(lambda *_: None, on_raw_event)
    try:
        listener.start(device_path)
        finished.wait(timeout=duration)
    except Exception as exc:  # noqa: BLE001 - guided CLI must report hardware errors
        print(f"  监听失败: {exc}")
        return False
    finally:
        try:
            listener.stop()
        except Exception as exc:  # noqa: BLE001 - preserve the capture
            print(f"  停止监听失败: {exc}")

    events = recorder.events()
    output = _guided_capture_path(button)
    recorder.write_jsonl(output)
    if not first_signature or not finished.is_set():
        print(f"  {_GUIDED_LABELS[button]}未收到完整按下/释放，未修改映射")
        print(f"  诊断记录: {output}")
        return False

    binding = key_testing.binding_for_event(
        next(event for event in events if event.is_pressed), button
    )
    result = key_testing.evaluate_key_capture(
        events, button, physical_bindings=binding
    )
    if not result.passed or decode_errors:
        print(f"  {_GUIDED_LABELS[button]}采集失败，未修改映射")
        for error in decode_errors or result.decode_errors:
            print(f"  解码错误: {error}")
        print(f"  诊断记录: {output}")
        return False

    _save_physical_binding(binding)
    print(f"  {_GUIDED_LABELS[button]}完成，映射已保存")
    return True


def _guided(args: argparse.Namespace) -> int:
    try:
        paths = raw_input_windows.enumerate_matching_device_paths()
        device_path = hid_identity.select_single_device_path(paths)
    except Exception as exc:  # noqa: BLE001 - CLI must report the hardware failure
        print(f"cannot select one RC003 HID device: {exc}")
        return 2

    print(
        "Guided key test started; no volume or delete action will run.",
        flush=True,
    )
    results = []
    for index, button in enumerate(_GUIDED_BUTTONS, start=1):
        print(
            f"\n[{index}/{len(_GUIDED_BUTTONS)}] Press {button.upper()} "
            f"({_GUIDED_LABELS[button]}) once, then release fully.",
            flush=True,
        )
        results.append(_capture_guided_key(device_path, button, args.duration))

    passed = sum(results)
    print(f"\nGuided key test finished: {passed}/{len(results)} completed")
    return 0 if passed == len(results) else 1


def _replay(args: argparse.Namespace) -> int:
    events = key_testing.load_capture(Path(args.input))
    if args.signature and not args.button:
        print("--signature requires --button")
        return 2
    bindings = {}
    if args.signature:
        bindings[args.signature] = args.button
    elif args.button:
        first = next((event for event in events if event.is_pressed), None)
        if first is None:
            print("capture has no press event")
            return 1
        bindings.update(key_testing.binding_for_event(first, args.button))
    result = key_testing.evaluate_key_capture(
        events, args.button or "", physical_bindings=bindings
    )
    print(
        f"test {'PASS' if result.passed else 'FAIL'}: expected={args.button or 'none'} "
        f"press={result.saw_press} release={result.saw_release}"
    )
    for event in events:
        print(
            f"{'down' if event.is_pressed else 'up'}: "
            f"button={event.button_id or 'unknown'} "
            f"signature={raw_input_windows.physical_signature(event)}"
        )
    return 0 if result.passed else 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Capture and adapt RC003 physical keys")
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture = subparsers.add_parser("capture", help="capture one physical press/release")
    capture.add_argument("--duration", type=float, default=30.0)
    capture.add_argument("--output", type=Path)
    capture.add_argument("--assign", type=_button_id)
    capture.add_argument("--expected", type=_button_id)
    capture.set_defaults(handler=_capture)

    replay = subparsers.add_parser("replay", help="verify a saved capture offline")
    replay.add_argument("--input", required=True, type=Path)
    replay.add_argument("--button", required=True, type=_button_id)
    replay.add_argument("--signature")
    replay.set_defaults(handler=_replay)

    guided = subparsers.add_parser(
        "guided", help="逐个提示并采集返回、音量+、音量-"
    )
    guided.add_argument("--duration", type=float, default=20.0)
    guided.set_defaults(handler=_guided)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
