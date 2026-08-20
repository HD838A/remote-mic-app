# macOS System Dictation Is Not Triggered

- 时间：2026-08-20
- 状态：本机 RC003 + macOS 系统听写真机验收通过；正式签名发布候选待验收
- 影响范围：SayAll 1.9.3 build 125、macOS 26、Apple Silicon、RC003、MiRemoteV 2ch、macOS 系统听写
- 功能点：首次设置、语音键触发、Fn 注入、音频 pre-roll 与 drain
- 简单描述：遥控器音频完整到达虚拟麦克风，但 SayAll 没有启动 macOS 系统听写，因此最终没有文字。

## Reproduction

- Environment: SayAll 1.9.3 build 125, macOS 26.6.1, Apple Silicon, RC003 physical remote.
- Select `MiRemoteV 2ch`, choose `Other Voice Tool`, focus the onboarding transcript field, then hold and release the remote voice key.
- Expected: macOS Dictation starts, receives the remote audio, stops after release, and inserts text.
- Actual: the remote session starts, PCM reaches `MiRemoteV 2ch`, the stream drains and stops, but no transcript appears.
- Control: manually press Fn twice on the Mac keyboard, then hold the remote voice key. Text appears successfully.

## Log Evidence

The 2026-08-20 02:09-02:10 runtime samples show repeated complete RC003 sessions with `route=virtual_audio`, non-zero samples, zero enqueue failures, and successful drain. Each transcript capture ends with timeout or no text change. Permissions are recorded as `input=true accessibility=true`.

## Root Cause

`OnboardingVoiceTool.other` disables `voiceFnTapModeEnabled`. The RC003 voice session therefore only streams audio and retains the hardware Fn-hold mapping. macOS Dictation is not a hold-to-talk target and never receives a start/stop shortcut. The existing Fn-tap controller is intentionally specialized for Typeless and emits plain Fn, not the macOS system `Fn-D` dictation toggle.

## Fix

- Add an explicit macOS Dictation onboarding target.
- Reuse the existing pre-roll, drain, cancellation, and paired-toggle lifecycle.
- Inject Apple's system `Fn-D` dictation shortcut at session start and after audio drain instead of plain Fn.
- Keep buffering for 450 ms after the opening shortcut so Dictation is ready before pre-roll playback; disabling or disconnecting during that window sends the paired closing shortcut.
- Keep Typeless on plain Fn tap and keep all other tools on their existing behavior.

## Verification Boundary

Automated tests cover shortcut event shape, permission failure, onboarding persistence, existing Typeless behavior, and source-level UI wiring. The original RC003 + MiRemoteV 2ch + macOS Dictation journey passed on an isolated local development build. Release acceptance still requires repeating the journey on a Developer ID signed and notarized candidate.

## Verification Results

- `./scripts/test.sh` with package build skipped: 45/45 project self-checks passed, including the new onboarding route, activation-delay pre-roll, and interruption cleanup cases.
- `swift build -c release`: passed. Existing macOS 14 `onChange` deprecation warnings remain unchanged.
- `git diff --check`, Swift parse, and both localization plist checks: passed.
- Swift Testing target: the production app compiled and linked, but the local Command Line Tools installation does not provide the `Testing` module, so the Swift Testing files could not execute locally. They remain available for CI/full Xcode.
- Local RC003 + macOS Dictation acceptance on 2026-08-20: passed. Four consecutive sessions delivered 16,320-222,240 samples with zero enqueue failures; each session emitted a successful opening Fn-D tap, drained audio, and emitted a successful closing Fn-D tap.
- The onboarding flow advanced from `voiceTest` to `controls`. That transition requires a started and ended voice session, non-zero samples, non-empty transcript, and no confirmed physical-keyboard input. No `manual_keyboard_input` event was recorded, and the tester confirmed that dictated text appeared normally.
- The local acceptance app used the isolated bundle identifier `com.dinga1981.RemoteMic.DictationTest` and an ad-hoc development signature because this Mac has no Developer ID signing identity. It was not installed over the notarized production app and is not a distributable artifact.
- Developer ID signed and notarized release-candidate acceptance: pending.
