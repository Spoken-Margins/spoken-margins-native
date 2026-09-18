# iOS 26 baseline and iOS 27 support — September 16, 2026

Status: implementation complete; compatibility verification is partial. The remaining iOS 27 speech check is blocked by a reproduced Apple simulator API/service failure. This is not a claim that every simulator crash is fixed or that the candidate is ready for distribution. Simulator testing remains authorized; no runtime blacklist is installed.

## Candidate and scope

- Lane: `codex/provisional-next`; app version/build 0.1 (27), uncommitted changes.
- Starting HEAD was `c81d5dbd7b7d081369a2baf36a05c6833f92d7a3`. Concurrent owner-authorized video-history cleanup rewrote the base to `807f111dc10eac6671b98a32b4801310456e2f1b`; neither SHA alone identifies this dirty candidate. Execution manifests retain HEAD and input-content hashes.
- App, extensions, tests and SessionKit now require iOS/iPadOS 26. SessionKit retains macOS 15. Toolchain: Xcode 27.0 (27A266a), SDK 27.0.
- Baseline-only cleanup removes 53 net production Swift lines across four files. The separate keyboard-layout repair adds UI code, so 53 is not the net reduction of the entire task diff.
- Model readiness/eligibility, locale support, resource/error PDFKit fallback, persistence compatibility and macOS support remain intact. No schema migration.
- The Add Source pasted-text action and Done button now share one bottom inset, resolving the observed iOS 27 accessibility-size overlap.
- Runner selection enforces the supported OS floor and exact `--ios`/`--device` requests. It monitors new crash reports for all processes on the selected simulator, terminates the command and shuts down on a report; it does not retry or blacklist a runtime. Report delivery can be delayed, so zero dialogs cannot be guaranteed.
- No commit, physical-device installation, distribution, runtime deletion or erasure of an existing simulator was performed. A fresh diagnostic simulator was created and retained; original app containers were preserved.

## Verification

Evidence paths below are relative to `artifacts/test-runs/`.

| Check | Result | Evidence |
|---|---|---|
| Fast: runner, browser, package, contracts, surfaces, inventory | Passed after runner crash-monitor changes; 22 infrastructure tests | `20260916-105448-206784-fast/manifest.json` |
| Initial iOS 26 app / adapters / UI / speech | 450 / 11 / 14 / 1 passed before final keyboard repair | `20260916-093804-909660-app`, `20260916-094210-675637-adapters`, `20260916-094250-786782-ui`, `20260916-095444-819751-speech-canary` |
| Final iOS 26 phone keyboard regression | Passed | `ios26-final-keyboard-supervised/manifest.json` |
| Final iOS 26 iPad UI suite | All 14 passed, 619.691 seconds, no new crash observed | `ipad26-final-ui/manifest.json` |
| Final iOS 26 app suite | All 450 passed, 76.872 seconds | `ios26-final-app/manifest.json` |
| iOS 27 app / adapters | 450 / 11 passed before final keyboard repair | `20260916-095837-907105-app`, `20260916-100408-919511-adapters` |
| Initial iOS 27 UI | 13/14 passed; keyboard overlap exposed | `20260916-100547-697365-ui/manifest.json` |
| Final iOS 27 phone keyboard regression | Entire route passed on fresh device, no new crash observed | `ios27-fresh-device-keyboard/manifest.json` |
| Final iOS 27 speech | Interrupted by Apple AppIntentsLiveEntityService crash; not passed | `ios27-fresh-device-speech/manifest.json` |
| Generic iOS device compilation | Passed, signing disabled; no installation | `ios26-final-keyboard-supervised/device-build.log` |

These results combine initial platform checks and focused final-source regressions; they are not a full final-source iOS 27 release pass. Product-owner validation is pending. Watch work was not in scope.

## Simulator diagnosis: three distinct failures

1. **PosterBoard:** 42 matching reports trapped while initializing a poster descriptor. All five stored ClockPoster configurations lacked descriptor identifiers; three other configurations and the iOS 26 comparison had identifiers. SQLite integrity was OK. The store and two preferences were moved to an external reversible backup (`posterboard-repair.json` records exact paths). The recovery probe rebuilt eight valid entries, including five clocks, and observed 60 stable seconds without a new PosterBoard report. This repairs the observed state; the original corruption mechanism is unknown.
2. **WidgetRenderer_Default:** a separate SIGILL on `_AXDyldImageMonitor` occurred during testing of the original device. Its underlying cause is unresolved. The fresh-device keyboard run did not reproduce it. Duplicate accessibility-class warnings also appear on the working iOS 26 runtime and do not isolate this fault.
3. **AppIntentsLiveEntityService:** the same Swift XPC assertion occurred on both the original and fresh iOS 27 devices. The standalone public C API probe returns `XPC Peer Requirement requires LWCR support.` on both simulators and succeeds on the native Mac host. The service stack calls the Swift wrapper for this failing constructor. This establishes a simulator-capability boundary independent of Spoken Margins. See `xpc-probe/README.md`, the small source file, and all three outputs. No security policy or Apple binary was changed.

The fresh-device boot and keyboard checks initially passed, but the later speech failure falsified a device-state-only explanation. Apple `simctl runtime verify` returned the same sealed-resource error for iOS 26 and 27, so that result does not justify claiming a uniquely damaged iOS 27 installation or reinstalling it.

**Concrete blocker:** uninterrupted iOS 27 simulator verification requires an Apple runtime/toolchain correction or supported workaround for the missing XPC requirement capability. A repository change cannot supply it inside Apple's service. Physical-device verification could provide separate app evidence; it would not establish a simulator repair. No report has been sent externally.

## Destinations and retained evidence

- iOS 26.5 phone: `D0C61450-3252-4DCE-B840-8C5AD56C3D1B`.
- iOS 26.5 iPad: `BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51`.
- Original iOS 27.0 phone: `6EA9B511-6F76-4AC0-BBDC-CFF819D78A9B`.
- Fresh iOS 27.0 diagnostic phone: `56328E32-FF5F-49DF-8CD1-1B498D8AD32E`.
- Runtime builds: 26.5 = 23F77; 27.0 = 24A434. Simulator and physical-phone build identifiers need not match.
- Earlier interrupted/failed attempts remain evidence, not passing retries. The initial Xcode post-test diagnostic collection stall led to `-collect-test-diagnostics never`; raw logs, test reconciliation and xcresults remain retained.
- The outer supervisor interrupted speech before normal manifest finalization; its manifest was explicitly annotated failed/incomplete afterward, with the crash path and explanation.

## Product-owner handoff boundary

No human validation is requested as a release gate while the platform blocker remains. If proceeding later, preserve the owner's Library and install normally without UI-testing launch arguments. Synthetic simulator routes seed **You Can't Inspect the Pill**, **A walk with room to think**, and other fixtures; those reset paths must not be used on the owner's phone.

Pending owner checks: Library/position/Margins survive upgrade; article/podcast playback and pause/skip; record/save/cancel a Margin; Lock Screen/headphone/background playback; offline episode playback; Safari/PDF intake; local-model availability messaging; diagnostics export. None is inferred from automated success.

Diagnostics are available in Settings → Developer tools. Automatic playback history: app container `Library/Caches/DeveloperDiagnostics/playback-events.json`; opt-in detailed recording: `Library/Caches/DeveloperDiagnostics/latest.json`. Existing product exceptions from the September 15 reliability handoff remain applicable.
