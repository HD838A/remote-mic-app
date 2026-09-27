# Contributors

This file records the external contributors whose work this repository has **adopted or relied on**. It is an attribution record, not a current product specification, and it does not replace the licensing information in [`LICENSE.md`](LICENSE.md), [`COPYRIGHT.md`](COPYRIGHT.md) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Maintainers are not listed here; this file only records verifiable contributions by authors outside this repository.

## Rules for recording

- Record a contribution only after this repository has adopted it or actually cited it in a fix or decision. Do not record work that was submitted but not adopted.
- Every entry must cite a verifiable source (issue or PR number) and state the specific contribution. Do not write generic "thanks for contributing" lines.
- When citing someone else's issue report, minimal experiment or PR, credit them here and in the corresponding `Bugs/` record at the same time.

## Current entries

| Contributor | Contribution | Source |
| --- | --- | --- |
| [@peterhon168](https://github.com/peterhon168) | Identified the root cause of event tap accumulation in long-running background sessions (`KeyboardEventSuppressor.stop()` never calls `CFMachPortInvalidate` on the underlying `CFMachPort`) and provided a minimal controlled experiment: 100 create/stop cycles left 100 taps behind without the invalidate call, and 0 with it. That root cause and experiment are the direct basis for this repository's fix. | [#476](https://github.com/HD838A/remote-mic-app/issues/476) |
| [@btiger](https://github.com/btiger) | Submitted a partial fix (adding the missing invalidate to `KeyboardEventSuppressor.stop()`) and added independent corroboration on the same environment in #476: a single process instance in the local `runtime.log` ran continuously for 4.96 days with 1,039 `HID START` cycles, reconciled against the 2,378 leftover taps measured in #476 (≈13% deviation). Those log statistics are now folded into [`Bugs/2026-09-27-event-tap-port-not-invalidated.md`](Bugs/2026-09-27-event-tap-port-not-invalidated.md). | [#493](https://github.com/HD838A/remote-mic-app/pull/493), [#476 comment](https://github.com/HD838A/remote-mic-app/issues/476#issuecomment-5827054801) |
| [@L33Z22L11](https://github.com/L33Z22L11) | Independently reproduced the same symptom on `SayAll 1.9.21 (174)` / `macOS 26.6.2`, measuring **1,872 disabled event taps** after roughly 4 days in the background versus 1 after a restart. This evidence extends the defect beyond macOS 27 and is why this repository does not classify it as an macOS 27 regression. | [#446 comment](https://github.com/HD838A/remote-mic-app/issues/446#issuecomment-5805743571) |
| [@idootop](https://github.com/idootop) | First to report the symptom as "after long background running and repeatedly opening and closing the lid, trackpad gestures become extremely laggy; quitting SayAll restores them", providing the first reproducible user-side description. | [#446](https://github.com/HD838A/remote-mic-app/issues/446) |
| [@leafney](https://github.com/leafney) | The earliest report of the same class of symptom (system-wide stutter after long running, restored by quitting SayAll). | [#337](https://github.com/HD838A/remote-mic-app/issues/337) |
