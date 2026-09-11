# Second-edition native candidate

Status: implemented and verified development candidate; owner validation remains pending.

## Candidate identity

- Lane: `codex/provisional-next`.
- Base commit: `ec2155707b3f416932123c4bf56d939fb209d4ba`, with the native redesign still uncommitted. A base SHA alone does not identify this candidate; use the verification input hash recorded below.
- Local app version: **0.1 (26)**. This is a development candidate, not the distributed TestFlight Build 26 (`9c967793e7a0e86c26a3030390818e87d830723b`). Build 27 remains available for a later explicitly authorized upload.
- Project support: iPhone and iPad, iOS 18.0+. Actual tested destinations and exact OS versions are listed with the final results below; the deployment target alone is not runtime evidence.
- Design authority: `docs/second-edition-reference-snapshot.md` freezes the approved second edition. The published Site and existing proposal changes are preserved.

## In scope

The native Library, fixed player controls, voice capture/review, global Margin retrieval and star curation, explicit return to a saved source moment, written capture and microphone recovery, Add, Following, Item/readiness, Timeline, sender and recipient review, offline/storage, settings, completion/replay, and Skim/shared return controls. Existing persistence, source matching, audio ownership, disclosure, and protected-original rules remain part of acceptance.

Voice capture retains the existing resume-after-Save/Cancel policy. Written capture restores the prior play/pause state.

Written capture is a canonical persisted transaction. It stores the user's exact words and the heard target/position, restores the prior play/pause state, retains a failed-save draft, and does not create a recording or transcription job. Legacy missing recordings retain their recovery behavior. Global browsing and star changes are addressed by session and do not replace the active source; **Play this moment** is the explicit switch.

Out of scope: distribution, promotion to `main`, Watch expansion, accounts/cloud sync, co-op replies, new audio/inference engines, and new source-alignment algorithms. Test evidence does not establish real-world audibility, Bluetooth/Lock Screen behavior, thermal performance, or owner acceptance.

## Reproducible setup and recovery

Use an isolated simulator or a dedicated development test device for synthetic fixtures. The verification runner selects the exact simulator with `--device`; it does not require erasing a personal Library. The UI suite launches with `--ui-testing` and explicitly seeded scenarios. Recording-route fixtures exercise lifecycle and controls; they are not evidence that a person's microphone recording sounds correct.

Baseline fixture: the seeded Library includes the pill article, other distinct items and generated response examples. Expanded tests add a long-title text source, 50 distinct private Margins across sessions, colliding note IDs, Shared-layer records, and exact written text. The source fixtures and test methods are recorded in each run's manifest. Use your own content for the product check after reproducing the sample behavior.

For manual sample setup, open Library → Settings → Developer tools → **Reset Library and Load Sample**, then confirm **Reset Library**. Reset requires its destructive confirmation and is appropriate only for an isolated test Library. Do not reset a personal Library to work around a presentation issue. Restarting the app should retain saved Margins; cancelling an unsaved written draft should create no record.

Diagnostics: Library → Settings → **Copy Privacy-Safe Diagnostics**. For a targeted physical-device investigation, enable **Record Device Diagnostics** in Developer settings, reproduce once, then copy diagnostics. Recording is bounded and resets off on restart. Preserve the item/session identity, exact steps, screenshot and diagnostic export beside the owner checklist.

## Evidence and owner decision

Frozen candidate input: `de27462fa86d9c071062ed9bf7a539e8b0fd0551c4efcbffaab79d3ed42e060b`. The exact implementation-file digests are in `artifacts/reviews/second-edition/integration-final-inputs.json`.

The prior integrated candidate (`7632bd366c275aa8596a1a1d0210eb4ee9bf7fd76de210b0a0aba46d81e8f2bb`) passed all 437 release cases, ten iPad UI routes, five small-phone iOS 18 routes, fast checks and both generic builds. Direct OS dark-mode inspection subsequently exposed the mini-player's white glyph on a light-green background. The final four-binding repair uses the existing contrast-tested foreground: approximately 10.33:1 in dark mode, with the same white foreground in light mode. A reconstructed digest proves this is the only implementation delta: `artifacts/reviews/second-edition/dark-contrast-delta.json`.

Final-source release: **437 passed, zero failed or skipped**, including 402 app cases, eight adapter cases and 27 UI cases. The same release run passed ten runner tests, 11 browser tests, 285 package tests and validators; one explicitly allowed held-out package benchmark was skipped. Evidence: `artifacts/test-runs/20260910-202149-769328-release/manifest.json`. Both generic simulator and device builds passed: `artifacts/test-runs/20260910-204454-generic-builds/manifest.json`.

The device matrix records ten passing iPad routes and five passing iOS 18 small-phone routes under their actual prior source identity. A reconstructed input digest proves the final delta consists solely of four dark-mode foreground bindings with unchanged white foregrounds in light mode. Final phone release execution and direct dark Library/player/writing captures use the final hash. Capture metadata: `screenshots/os-appearance/final-evidence.json`; behavioral results: `execution-index.json`; matrix: `device-matrix.json`.

No new native flow is human_validated. Work remains uncommitted. Final observed account usage was 81% used / 19% remaining, one point below the authorized floor; development stopped and only the already-running local verification and handoff were closed out. Account usage is shared and is not task-only attribution.

The final fixes also include complete Margin-row hit targets on iPad, real short-content pull geometry, keyboard/mini-player clearance, and an iOS 18 back button whose center had been intercepted by the edge-swipe overlay. Native captures and failure diagnoses are preserved under `artifacts/reviews/second-edition/`.

The supplied iPad startup crash came from a stale pre-test installation restoring at simulator boot. Binary UUID/dependency comparison identified the mismatch; the current candidate subsequently installed, launched and executed all ten iPad UI seams. Evidence: `artifacts/reviews/second-edition/ipad-launch-diagnosis/diagnosis.md`.

Known presentation limitation: at the largest accessibility text size on the small phone, the Add label and some secondary metadata have little breathing room. The tested actions remain reachable, but individual comfort is an owner check.

### Remaining owner evidence

- Real microphone audibility, speech recognition quality and playback balance.
- Headphone/Bluetooth, Lock Screen and physical interruption/restoration behavior.
- VoiceOver traversal, preferred real-device text settings and one-handed comfort.
- Upgrade of a real beta Library and your own source/import/share collection. The automated prior-build fixtures are synthetic; they are not a captured personal Library.
- Safari PDF delivery through the actual OS share sheet retains its existing manual evidence requirement. Bundle checks and helper tests do not prove this OS handoff.

No current finding establishes a loss of saved data; this statement is limited to the tested cases and does not replace an upgrade check. Native screenshot coverage is indexed separately from behavioral test coverage. Failed and interrupted attempts remain under `artifacts/test-runs/`; none count as passing evidence.

Use [the product-owner checklist](product-owner-checklist.md) to record device, OS, date, pass/fail and observations. Only the owner may mark a redesigned flow `human_validated`. This handoff does not request or imply a release upload.
