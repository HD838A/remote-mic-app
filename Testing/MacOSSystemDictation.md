# macOS System Dictation Trigger Test

## Applies To

Branch `codex/system-dictation-trigger`, based on SayAll 1.9.3 build 125.

## Preparation

- Apple Silicon Mac running a supported macOS version with Dictation enabled.
- Xiaomi Bluetooth Remote 2 Pro (RC003), paired and connected.
- `MiRemoteV 2ch` installed and selected in SayAll and macOS Dictation.
- Bluetooth, Input Monitoring, and Accessibility permissions granted.
- A signed and notarized test build; fully quit the previous SayAll build before launching it.

## Primary Journey

1. Restart first-use setup and choose **macOS Dictation**.
   - Expected: the target is selected and tap-toggle voice triggering is enabled.
   - Failure: the option is absent, selection is lost, or the app falls back to Other Voice Tool.
2. Continue to the voice test and focus the transcript field.
   - Expected: the insertion point remains in the field.
   - Failure: focus moves away before voice starts.
3. Hold the RC003 voice key, immediately say a short sentence, then release.
   - Expected: Dictation starts through Fn-D, the beginning of the sentence is preserved by pre-roll, and text appears once.
   - Failure: Dictation does not open, the first word is lost, no text appears, or two transcript copies appear.
4. Repeat three times, including one press shorter than one second and two normal three-second presses.
   - Expected: every session produces exactly one start/stop pair and the next session remains usable.
   - Failure: Dictation remains open, toggles back on after release, or a later session is ignored.

## State and Permission Cases

1. Remove Accessibility permission and try to enable the mode.
   - Expected: SayAll requests permission and does not inject the shortcut until granted.
2. Disconnect during speech, reconnect, and retry.
   - Expected: any pressed synthetic key is released and the next session works.
3. Disable tap-toggle mode during speech.
   - Expected: the current pair is safely completed without reopening Dictation.
4. Repeat with the iPhone and web control methods.
   - Expected: Fn-D starts before audio and stops only after drain.

## Stable Regression

- Typeless still receives one plain Fn tap at start and one at stop.
- Doubao, WeChat Input Method, and Other Voice Tool retain their existing Fn behavior.
- Normal button mappings, audio test tone, RC003 connection, and `MiRemoteV 2ch` output still work.
- Settings pages remain readable at 800 x 650 in light and dark appearance.

## Logs

Collect `~/Library/Logs/RemoteMic/runtime.log`. A passing system Dictation session must show the system-dictation trigger route, non-zero PCM samples, audio drain, and a paired closing trigger without injection failure.

## Verification Boundary

Unit tests and builds prove event generation and lifecycle boundaries only. They do not replace the signed-build RC003, real macOS Dictation, focus, audio, and final text acceptance above.

## Local Acceptance Result — 2026-08-20

- Environment: macOS 26 on Apple Silicon, SayAll 1.9.3 build 125, RC003, and `MiRemoteV 2ch`.
- Build: isolated local development app using bundle identifier `com.dinga1981.RemoteMic.DictationTest`; the notarized production app was not replaced.
- Four consecutive RC003 voice sessions completed with 16,320, 62,400, 91,440, and 222,240 samples and zero enqueue failures.
- Every session logged a successful opening Fn-D tap, audio drain to zero pending buffers, and a successful closing Fn-D tap.
- The onboarding flow advanced from `voiceTest` to `controls`, with no confirmed physical-keyboard-input event, and the tester confirmed that dictated text appeared normally.
- Result: local real-hardware journey passed. Repeat on a Developer ID signed and notarized release candidate before distribution.
