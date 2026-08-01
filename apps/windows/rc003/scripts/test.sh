#!/usr/bin/env bash
# Runs every test in apps/windows/rc003/tests that can run on this machine.
#
# On non-Windows hosts this exercises all pure-Python protocol/identity/config
# helper/privacy-contract/build-artifact tests; the Windows-only tests in
# tests/windows/ self-skip here (they need SendInput/hidapi/winrt/PortAudio)
# and print a skip reason rather than silently passing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 -m py_compile "$ROOT"/src/ovb_rc003/*.py

PYTHONPATH="$ROOT/src${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m unittest discover -s "$ROOT/tests" -t "$ROOT" -p "test_*.py" -v
