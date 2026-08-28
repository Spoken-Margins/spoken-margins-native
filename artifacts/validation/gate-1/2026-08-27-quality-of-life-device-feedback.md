# Quality-of-Life Device Feedback — 2026-08-27

- Reporter: product owner
- Device and OS: not supplied
- Installed build and commit: not supplied
- Scope: only the bounded behaviors explicitly reported below

## Accepted results

The product owner exercised and accepted these flows, advancing only these
specific behaviors to `human_validated`:

- Home scrolling with the populated library was smooth: PASS.
- In-app podcast scrubbing responded smoothly: PASS.
- The 5 GB offline-storage budget reconciled below its cap at 4.76 GB: PASS.
- A podcast past 25% progress with interjections exposed Follow Podcast: PASS.

## Failing results retained for remediation

- Following a podcast failed with “The feed exceeds the 2 MB safety limit.”
- Selecting the Article library filter transiently clipped its leading “A” before
  the control received more width.
- Compact playback showed a speedometer icon instead of the current playback
  speed.

The failing behaviors are product-owner evidence, not accepted flows. Their
subsequent implementation and automated checks remain `verified` until the
product owner exercises the remediated build.

## Remediation verification

- The bounded feed ceiling is now 16 MiB. The parser retains its 200-entry
  safety ceiling, while Quick Add keeps only the newest 25 actionable entries
  per followed feed. Older actionable records are pruned; imported and
  dismissed suppression tombstones remain.
- The filter label uses stable intrinsic sizing with implicit transition
  animation disabled.
- Compact playback renders the current numeric speed instead of a speedometer.
- A synthetic end-to-end follow of a 30-entry podcast feed larger than 2 MiB
  retained the newest 25 entries, pruned an older unseen record, and preserved
  imported and dismissed suppression records.
- All 46 source-link/follow tests passed.
- All 184 SessionKit tests passed.
- Contract and surface-contract validation passed.
- Generic iOS Simulator and generic iOS device builds passed.
- After the regression passed, persistence ordering was hardened to save retained
  entries before pruning stale ones. A focused rerun compiled the final code and
  launched the simulator app, but XCTest did not attach; the hung runner was
  stopped without claiming an additional test pass.

## Evidence boundaries

No device model, OS version, build number, diagnostics export, feed URL, or
repeat count was supplied. This record does not infer those details or extend
acceptance to other storage, followed-source, playback, or library-filter cases.
