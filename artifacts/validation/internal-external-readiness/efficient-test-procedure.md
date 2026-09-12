# Efficient engineering test procedure

Purpose: obtain evidence for the changed behavior and the eventual release without spending model usage repeatedly interpreting unchanged progress. Required verification remains governed by [AGENTS.md](../../../AGENTS.md) and [docs/testing.md](../../../docs/testing.md).

## Current stopping point

Current uncommitted repairs are based on `4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60`. See [September 12 repair evidence](september-12-retry.md) for the current input hash, checks and remaining device rechecks. Current button-only checks passed: 417 app tests, fast, and one scoped quick-tap UI test with separately inspected video evidence. The preceding 15 scoped audio/UI tests describe the previous input; audio implementation is unchanged. Earlier 409-test chapter evidence and the 444-test release/archive evidence describe superseded inputs.

Do not repeat completed development checks for documentation-only updates. A commit SHA change alone does not invalidate matching implementation inputs. Release/archive evidence must match the eventual exact candidate.

## When another code fix is needed

1. Identify the affected boundary and a focused regression that would fail for the reported defect. Finish the fix and focused diagnosis before starting broad verification. For scrolling, code/build checks support implementation; a same-device reproduction or trace supports performance.
2. Freeze implementation inputs. Run the applicable development plans once: fast and app for app work; adapters for OS audio/inference changes; speech-canary when speech input/playback changes; scoped UI checks for affected UI seams. Use the existing runner and selections in docs/testing.md. Do not run every plan merely because it exists.
3. Keep one verification runner active. Serialize Simulator-dependent testing and archive/build work. Let the runner enforce deadlines, collect logs and write its manifest. Prefer process waits and compact completion/failure output. Read detailed logs only to answer a specific question; keep required progress updates brief.
4. Rerun only for changed inputs, a diagnosed failure or an unresolved concern. Record the reason and preserve failed/incomplete evidence. After an unchanged failure survives diagnosis and one justified retry, report the blocker and continue independent work. Missing tests, unexpected skips and interruptions never count as passes.
5. Stop when required checks pass. Hand off the result and remaining owner checks; do not expand testing to occupy waiting time.

## Once the candidate is ready for release verification

Use the repository root. Choose current available destinations with `xcrun simctl list devices available`; the placeholders below must be replaced with actual UDIDs.

```sh
.venv/bin/python scripts/verify-tests.py --plan release --device PHONE_UDID
.venv/bin/python scripts/verify-tests.py --plan ui --device IPAD_UDID
```

Run these sequentially on frozen inputs. Release already includes fast checks and the active app/audio/UI tests, including the speech canary. Do not automatically precede it with duplicate full app, adapter, phone UI and fast runs when focused development verification has already passed. The iPad run supplies the additional layout destination required for release handoff.

Then perform the required generic-device, signed archive/export and bundle checks using the recorded release configuration. Reconcile the available build number, preserve the exact source and replace the superseded archive only with a clearly identified new candidate. Retain manifests and archive identity; an old IPA bearing the same build number is not interchangeable.

Document build/setup/test durations, source hash, executed counts and any failure/retry reason. Do not infer usage savings from elapsed test time. Before owner acceptance, fill the installation identity in [the current checklist](current-validation.md). Keep internal distribution and external review in the authorized release sequence.
