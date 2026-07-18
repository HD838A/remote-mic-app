"""``python -m ovb_rc003`` (or the packaged ``OpenVoiceBridgeRC003.exe``,
built from the standalone ``src/launcher.py`` entry point - see XRBM-021):

- (no args)     run the bridge - guarded by a per-session Windows named-
                mutex (single_instance.py) so a second concurrent launch
                never starts BLE/HID/audio: it shows a visible notice and
                exits with a deterministic nonzero code instead of ever
                calling ``app.main()``. This guard FAILS CLOSED (XRBM-021
                review round 1 P1 #1): if the mutex API itself could not be
                used to prove single ownership - not just a confirmed
                duplicate - the bridge does not start either. A caller
                that cannot prove it is the only owner of BLE/HID/audio
                resources must never gamble on being one anyway.
- ``--settings``  open the settings window
- ``--dry-run``   import every first-party module and exit 0, touching no
                  GUI, BLE, Raw Input, or audio device - the safe smoke
                  check build-candidate.ps1 and
                  .github/workflows/windows-rc003-ci.yml run against a
                  freshly built artifact (XRBM-014 review RETRY P2 #3: a
                  build that produces an executable which cannot even be
                  launched is not caught by the PyInstaller build step
                  alone).
- ``--help``/``-h``  print this usage and exit 0

``--settings``, ``--dry-run`` and ``--help``/``-h`` are all checked and
dispatched BEFORE the bridge branch below is ever reached, so none of them
touch the single-instance mutex at all (XRBM-021 changed threat model: the
guard applies only to the no-argument bridge mode).
"""

from __future__ import annotations

import sys

from . import __version__


def _print_help() -> None:
    print(f"Open Voice Bridge - RC003 Windows client (source/build candidate) {__version__}")
    print("Not yet real-device verified - see this package's README.md 'Known gaps' section.")
    print()
    print("Usage:")
    print("  python -m ovb_rc003              run the bridge")
    print("  python -m ovb_rc003 --settings    open the settings window")
    print("  python -m ovb_rc003 --dry-run     import every module and exit 0 (CI smoke check)")
    print("  python -m ovb_rc003 --help        show this message and exit 0")


def _dry_run() -> int:
    """Imports every first-party module this package ships, without
    constructing a Tk window, opening a BLE connection, starting Raw Input,
    or touching an audio device. Importing ``settings_ui`` only imports the
    ``tkinter`` module - it does not construct any widget or window.
    """

    from . import (  # noqa: F401
        app,
        atvv_protocol,
        atvv_session,
        audio_output,
        audio_playback,
        ble_transport_winrt,
        config,
        connection_supervisor,
        device_profile,
        frida_compat,
        hid_identity,
        hotkey,
        identity,
        key_mapping,
        logging_setup,
        raw_input_windows,
        resources,
        settings_ui,
        single_instance,
        voice_controller,
        win32_input,
        win32_keys,
    )

    print("dry-run: all ovb_rc003 modules imported successfully")
    return 0


def _run_bridge() -> None:
    """No-argument bridge mode: guarded by the per-session single-instance
    mutex (XRBM-021 In-scope items 2-3). ``app.main()`` is only ever called
    from INSIDE the guard's ``with`` block (first owner) - NEVER from any
    failure branch below. This fails CLOSED (XRBM-021 review round 1 P1
    #1): a confirmed duplicate and an acquisition failure the guard could
    not resolve are both treated as "cannot prove sole ownership", so both
    show a visible notice, exit nonzero, and never start BLE/HID/audio - a
    caller that cannot verify it is safe must not start anyway.

    ``MutexCleanupError`` (raised from the guard's ``__exit__``, i.e. AFTER
    ``app.main()`` has already run to completion or raised) is also caught
    here: the packaged executable is windowed (``console=False``), so an
    unhandled exception's traceback would never be seen by the user at all
    - this still needs a visible, SANITIZED notice (not the raw exception
    text, which is for diagnostics/stderr only) and a deterministic nonzero
    exit rather than silently disappearing.
    """

    from . import app, single_instance

    try:
        with single_instance.BridgeInstanceGuard():
            app.main()
    except single_instance.DuplicateInstanceError as exc:
        single_instance.show_bridge_startup_blocked_notice(str(exc))
        raise SystemExit(single_instance.DUPLICATE_INSTANCE_EXIT_CODE)
    except single_instance.SingleInstanceUnavailableError as exc:
        single_instance.show_bridge_startup_blocked_notice(
            "Open Voice Bridge · RC003 could not verify no other instance "
            f"is already running, so it will not start. ({exc})"
        )
        raise SystemExit(single_instance.GUARD_UNAVAILABLE_EXIT_CODE)
    except single_instance.MutexCleanupError as exc:
        # Diagnostic detail (fixed operation names/error codes only, per
        # single_instance.py's "no raw handle" contract - see that
        # exception's own message construction) goes to stderr for anyone
        # who can see it; the user-visible notice stays a fixed, sanitized
        # sentence regardless of the exact underlying failure.
        print(f"single-instance mutex cleanup failed: {exc}", file=sys.stderr)
        single_instance.show_bridge_startup_blocked_notice(
            "Open Voice Bridge · RC003 closed, but could not fully release "
            "its single-instance lock. If it will not start again, check "
            "Task Manager for a lingering process before retrying."
        )
        raise SystemExit(single_instance.CLEANUP_FAILED_EXIT_CODE)


def main() -> None:
    args = sys.argv[1:]
    if "--help" in args or "-h" in args:
        _print_help()
        return
    if "--dry-run" in args:
        raise SystemExit(_dry_run())
    if "--settings" in args:
        from . import settings_ui

        settings_ui.main()
        return

    _run_bridge()


if __name__ == "__main__":
    main()
