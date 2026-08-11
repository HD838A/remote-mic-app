# Voice input destination readiness investigation

## Observations

- User-visible failure: after a mapped button launches or focuses a target app, the first two Fn voice attempts can do nothing and the third succeeds.
- Field logs show the app action returns before the target input is focused:

  ```text
  15:37:44 APP ACTION opened bundle=com.openai.codex
  15:37:47 APP FOCUS succeeded bundle=com.openai.codex

  15:37:49 APP ACTION opened bundle=com.openai.codex
  15:37:51 APP FOCUS succeeded bundle=com.openai.codex
  ```

- `KeyboardInjector.send` returns `true` immediately after submitting an asynchronous application activation/focus request.
- `VoiceFnTapSessionController` independently posts Fn after a fixed 150 ms delay.
- There is no handoff proving that the frontmost app owns a safe editable Accessibility element before Fn is posted.
- The Fn controller and mapper sources are identical between `v1.8.3` and `v1.8.8`; onboarding and wider Typeless exposure made the existing race easier to encounter.
- Existing controller tests cover tap pairing and audio pre-roll, but no test composes target activation latency with the first voice stream.

## Hypotheses

### H1: Fn is posted before asynchronous target focus completes (ROOT HYPOTHESIS)

- Supports: field logs show 2-3 seconds between app-open and focus-success while the Fn controller waits only 150 ms.
- Conflicts: none.
- Test: simulate a target that becomes editable after 3 seconds and assert that the first Fn-down is not attempted before readiness.

### H2: The third-attempt behavior is caused by a counter in the Fn session controller

- Supports: the user observes a repeatable third-attempt success.
- Conflicts: no three-attempt counter exists; the controller starts every idle session the same way.
- Test: inspect and exercise consecutive sessions with identical timing.

### H3: The regression is a Codex-specific Accessibility selector failure

- Supports: the reported target app is Codex and it has a specialized composer focus strategy.
- Conflicts: the missing readiness handoff also affects Claude, cmux, custom apps, recorded fields, focus shortcuts and arbitrary shortcuts.
- Test: use a target-agnostic delayed editable-focus fixture rather than a Codex-specific candidate.

### H4: Audio is lost before the virtual device becomes ready

- Supports: the symptom is missing dictated text.
- Conflicts: existing pre-roll tests prove audio is buffered until the fixed Fn start tap; the field event order points to focus completing after Fn.
- Test: record buffered samples while readiness is delayed and require complete replay after readiness.

## Experiment

The regression test in `CoreVoiceInputJourneyTests` uses the production Fn controller with a simulated target that is not ready during the fixed 150 ms start delay. The key setter records any Fn-down attempted before the target becomes editable.

Observed on the old implementation: the test failed exactly as predicted. At 150 ms it recorded an Fn-down attempt while the simulated target was not ready, then recorded `start_tap_failed`; advancing to the target's 3-second readiness point produced no later Fn tap because the session had already been disabled. This confirms H1 and rejects H2 as the primary cause.

## Root Cause

`KeyboardInjector.send` acknowledges submission of asynchronous target activation/focus, while `VoiceFnTapSessionController` independently posts Fn after 150 ms; without a readiness handoff, Fn can reach the old or non-editable focus before the intended input exists.

## Fix

Added a shared destination-readiness coordinator, connected every external configured-action entry point to it, delayed only Fn sessions that have a recent target-switch request, expanded pre-roll to five seconds, and cancelled unsafe, superseded, changed or timed-out destinations. The original delayed-target reproduction, controller lifecycle tests and RC001/RC003 simulated hardware journeys now pass.
