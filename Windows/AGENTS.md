# RemoteMic Windows Agent Entry Point

## Mission

Deliver a usable RC003 Windows remote microphone from the existing validated behavior. The current two-day delivery track uses the existing Windows implementation as the product baseline. Do not start a C++ rewrite, WinUI migration, custom audio driver, or HID driver during this track.

## Read Before Editing

1. `docs/ai_context/INDEX.md`
2. `docs/ai_context/PROJECT_CONTEXT.md`
3. `docs/ai_context/CURRENT_STATUS.md`
4. `docs/ai_context/AI_HANDOVER.md`
5. Relevant ADR, module documentation, and tests
6. `git status --short`

## Mandatory Rules

- Inspect first, then modify.
- Preserve unrelated and uncommitted user changes.
- Keep secrets, tokens, Bluetooth addresses, UUIDs, voice data, and personal paths out of source control and production logs.
- A build is not proof of BLE, HID, audio endpoint, installer, or target-application behavior.
- Without a physical RC003, mark hardware validation `deferred`; never report it as passed.
- Keep production audio buffers bounded. Do not perform blocking file or process operations in an audio callback.
- New architecture or scope changes require an ADR.
- Update `CURRENT_STATUS.md` and `AI_HANDOVER.md` before switching models.
- Installer releases must support in-place upgrade: keep the stable AppId and
  install location, stop the old app, replace only versioned program payload,
  preserve config/key mappings/statistics/logs, and leave one installed-app
  entry. Never require the user to uninstall or delete an older installed
  version first. Portable ZIPs are exempt and must not be presented as
  auto-updating.

## Two-Agent Handover

GPT prepares the baseline, resolves high-priority blockers, runs the smallest relevant regression, and writes an executable handover. OpenCode/MiniMax M3 must first read the required files, inspect Git state, restate the current task, and run the handover's first safe command. It must not redesign the project during its first turn.

## Verification Vocabulary

- `passed`: actually executed and observed.
- `failed`: executed and did not meet the stated expectation.
- `deferred`: requires unavailable hardware, external app, account, or environment.
- `not_applicable`: the change cannot affect that boundary.
