# Changelog

## Unreleased contributor update

Originally developed from SayAll 1.9.8 and integrated with the latest upstream `main` before submission.

### Voice-button shortcuts

- Allow the physical remote microphone button to hold any recorded keyboard key, left/right standalone modifier, or key combination while the remote continues capturing audio.
- Preserve the original Fn behavior as the default and fallback; the configured shortcut is always loaded from the current profile and is never hard-coded to Left Control.
- Release held keys on button-up, stream stop, disconnect, mapping changes, permission changes, and normal app shutdown.
- Add inline warnings for dangerous system actions, known global shortcuts, Command menu commands, and unmodified typing keys without blocking advanced users.
- Keep the voice-button card consistent with the other remote buttons by retaining its single-click, double-click, and long-press presentation.

### Live microphone feedback

- Add a compact live input-level meter next to the connected remote's battery status.
- Drive the meter from the decoded remote microphone PCM level, with smoothing, throttled UI updates, and immediate reset when a voice session ends.
- Keep the existing mapping-page layout and voice-button configuration unchanged apart from the small status indicator.

### HID reliability and duplicate-action prevention

- Neutralize the native keyboard events emitted by all 12 regular RC003 buttons while custom mapping is enabled, preventing a configured action and the original system key from firing together.
- Map standalone voice-button modifiers at the HID layer so strict global-hotkey tools receive physical-equivalent press and release edges.
- Require readback of the requested voice mapping and all 12 native-button neutralization mappings before the HID monitor is considered ready.
- Retry incomplete HID setup with bounded delays after startup, reconnect, wake, permission changes, and configuration changes.
- Re-audit the live HID registry after an apparent success so keyboard services that enumerate late are also mapped.
- Preserve transactional rollback and fail closed when only part of a multi-service device was mapped.

### Reflections and temporary original audio

- Keep a local voice-session record even when a third-party input method prevents SayAll from safely reading the final transcript text.
- Improve transcript capture around third-party composition changes without storing the surrounding input-field contents.
- Add an opt-in setting to retain the original voice-session audio locally and play it from Reflections.
- Automatically expire retained audio after a maximum of four hours; deletion of a record, application group, or all history also deletes the corresponding audio.
- Keep transcript and audio storage local, exclude passwords and other protected input fields, and expose only safe history metadata through the existing MCP boundary.

### App identity and local testing

- Replace the app icon with a remote-and-voice design that matches the product's primary hardware workflow.
- Add an isolated `SayAll Dev` build with a separate bundle identifier, visible permission identity, and disabled automatic updates so local validation does not replace the installed release.
- Add HID acceptance logging, regression guides, rollback snapshots, delayed-service tests, shortcut-mode tests, audio-retention tests, and all-button gesture coverage.

### Verification status

- Project self-test: 67 passed, 0 failed on the integrated branch.
- Debug build and isolated local app build: passed on the integrated branch.
- Earlier pre-integration RC003 validation reached `BLE READY`; the active ordinary-key voice shortcut and all 12 native-button mappings passed four delayed HID registry audits. The final integrated branch still requires the hardware checks below.
- The local Command Line Tools environment cannot load Swift's `Testing` module, so the complete Swift Testing matrix must run in GitHub CI.
- Real RC003 checks for every button/gesture, sleep/wake, permission revocation, and multiple third-party speech tools remain release-acceptance requirements rather than claimed automated results.
