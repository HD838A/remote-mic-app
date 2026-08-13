#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/.build/self-test/RemoteMicSelfTest"

mkdir -p "${OUTPUT:h}"
xcrun swiftc \
  "$ROOT/Sources/RemoteMic/ATVVProtocol.swift" \
  "$ROOT/Sources/RemoteMic/BluetoothLifecycle.swift" \
  "$ROOT/Sources/RemoteMic/RemoteButtons.swift" \
  "$ROOT/Sources/RemoteMic/RemoteDeviceProfile.swift" \
  "$ROOT/Sources/RemoteMic/FirstUseDiagnostics.swift" \
  "$ROOT/Sources/RemoteMic/OnboardingFlow.swift" \
  "$ROOT/Sources/RemoteMic/AppSettings.swift" \
  "$ROOT/Sources/RemoteMic/AppLinks.swift" \
  "$ROOT/Sources/RemoteMic/Localization.swift" \
  "$ROOT/Sources/RemoteMic/VoiceFunctionKeyLatch.swift" \
  "$ROOT/Sources/RemoteMic/VoiceInputDestinationCoordinator.swift" \
  "$ROOT/Sources/RemoteMic/VoiceFnTapSessionController.swift" \
  "$ROOT/Sources/RemoteMic/RemoteVoiceFunctionMapper.swift" \
  "$ROOT/Sources/RemoteMic/AppLogger.swift" \
  "$ROOT/Sources/RemoteMic/TestTone.swift" \
  "$ROOT/Tests/SelfTest/main.swift" \
  -o "$OUTPUT"
"$OUTPUT"

xcrun swift build
