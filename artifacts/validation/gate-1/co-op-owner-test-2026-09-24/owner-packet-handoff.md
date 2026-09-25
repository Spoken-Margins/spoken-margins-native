# Co-op owner packet handoff — September 24, 2026

**Withdrawn as a readiness claim after owner test failure.** The owner reported that local and shared Margins did not play and Skim left source progress stranded at 19:08 on a physical iPhone. See `failed-device-run/incident.md`. The artifact integrity and automated results below remain historical evidence, but the packet must not be offered for another owner exercise until a corrected app build is verified.

Status: **implemented and host verified; owner validation pending**. This handoff supersedes the earlier `implementation-stop-2026-09-24.md` stopping point. The current app gate passed 484/484; the focused adapter gate remains blocked at zero tests.

## Candidate and test assets

- Branch `codex/co-op`, HEAD `34837c6055471297ca0b360c591f734bad5c2c82` plus the current dirty working tree. App version `0.1`, build number `27`. The code identity for the final fast gate is SHA-256 `56fb3503feba72267d9a8e73d00b219d3b6657571f432565fc1632dec6837a53` over verifier inputs. Build number 27 alone does **not** identify these changes; existing TestFlight Build 27 lacks conversation v2.
- Minimum supported iPhone/iPad OS is iOS/iPadOS 26. The automated app destination is an iPhone 17 Pro simulator on iOS 26.5. iPad/iOS 27 and physical-device behavior are not established for this change.
- Owner files: `/Users/colemiller/Downloads/SpokenMargins-Coop-Test-2026-09-24/SpokenMargins-Coop-Owner-Packet.zip` (SHA-256 `a73a4d717878a8557430119004d024c210badee95d73e033031207420b9f15a8`), containing the three numbered `.spokenmargins` files, README, AI audio previews, scripts and `generation-and-verification.json`. The README now marks the failed owner test. The original source input is `/Users/colemiller/Downloads/Jensen-Huang-Thinks-A.I.-Alarmism-Has-Gone-Too-Far-a12a1c2d.spokenmargins` (SHA-256 `d7d32000802deead64158727a3124aa0634b12a92d43126deb769f3ae87c6fbe`).
- The selected starting point is Cole's `margin-0002`, near 31:19. Alex and Blair target its exact legacy revision. Casey targets the exact Alex and Blair revisions, in that order. The three packet file hashes and separate archive digests are in `generation-and-verification.json`.

## Engineering evidence

- The final fast plan passed all required runner, contract, surface, inventory, browser and package steps: `artifacts/test-runs/20260924-124416-188876-fast/manifest.json`. Package tests: 347 passed, zero failed, one expected held-out-corpus skip. The new fork/import and invalid-graph tests passed within it.
- Final generic iOS Simulator and iOS device app builds passed. The new iOS two-target workflow test also executed and passed in the current app suite.
- The generator used the production package writer, archive reader and importer. All three archives round-tripped. Normal order and Casey-first, repeat-import order converged to four exact revisions, Casey's two exact targets, and a context traversal with Cole once. See the packet directory's `packet-verification.log`.
- The AI audio was generated with official Chatterbox Nano (`nano=True`) from synthetic reference voices. Final scripts were checked against a local Whisper transcription; Casey's irreversible-risk negation was retained. Final WAVs were detected by the model's watermark checker. Model revisions, hashes and measured preview durations are in `generation-and-verification.json`.
- The current iOS app plan passed **484/484**, zero failures/skips, on the same iPhone 17 Pro simulator (iOS 26.5): `artifacts/test-runs/20260924-124629-307864-app/manifest.json`. It used the same `56fb3503…` input as the fast plan and executed `testTwoTargetWrittenReplyKeepsCaptureAnchorAndPlaysSharedAncestorOnce`. The previously stalled latest app run executed zero tests; the current successful run is a separate, newer result. Earlier adapters 11/11, speech 1/1 and UI 16/16 passes predate this two-parent slice.
- A current-input `adapters` plan on that same phone built and reached simulator readiness, then timed out before XCTest connected: **0/11 executed**, not a pass or an app assertion failure. Evidence: `artifacts/test-runs/20260924-124918-614111-adapters/manifest.json`. The unchanged run was not repeated. The speech canary was not rerun after this connection failure; prior 1/1 is earlier-input evidence.

## Owner exercise and boundaries

Use a development app built from the current source, then follow the five pass/fail checks in the packet `README.md`: Alex alone, Casey alone and with context, Casey-first/repeated import, a new two-target reply, and export/reimport. Only the product owner can mark those flows `human_validated`. The package is ready for that exercise; the existing TestFlight binary is not.

In scope: ordered two-to-four exact reply targets, legacy one-parent import, additive packet import, ancestor-once playback context, explicit missing-parent state, source-anchor preservation, and reviewed forwarding. Out of scope: hosted/group delivery, authenticated participants, automatic AI responses in the app, full podcast audio in the packet, Watch runtime changes, release distribution, and a claim of device resource reliability.

Known issues/risks: the current adapter gate is blocked by an XCTest connection stall, although the current 484-test app run completed. This leaves a focused audio-runtime evidence gap for this input. Podcast source matching remains conservative and may present unresolved context instead of seeking. The iPad SpringBoard teardown incident bars an unchanged broad UI rerun. Manual packet import and a development binary are required.

Reset: for a soft retry, stop playback and reopen the episode. For Casey-first import, use an isolated recipient Library or disposable test installation; do not reset the real Library. To capture failures use Settings → developer diagnostics → “Copy Privacy-Safe Diagnostics,” retaining the packet and the app source identity. Stop on lost originals, wrong parent, audio failure, confidently wrong seek, duplicate revisions, or an unimportable export. Record each README pass/fail item and notes under this validation directory.

No commit, merge, physical-device installation or distribution was performed.

Account meter: 40% weekly used when this continuation began and 44% used after packet generation, app testing, adapter diagnosis and handoff (56% remaining). These are meter readings, not a per-command cost allocation.
