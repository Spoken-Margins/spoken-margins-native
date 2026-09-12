# Build 27 internal TestFlight handoff

Status: corrected Build 27 uploaded successfully, processed by Apple, and confirmed **Testing** in the internal **Margins** group with **seven testers**.

## Exact identity

- Version: 0.1 (27); bundle `com.spokenmargins.native`; team `J8SWC6J3VY`.
- Uploaded source: `adeb923fc1d081b19dfe9d650b50ac9fb036535a` on `codex/provisional-next`, preserved by `testflight/0.1-build-27`.
- Verification input: `ead7d30e89f97d757fa02b19c42fc37185c04e8a9d0149428c452d06718dc476`.
- IPA SHA-256: `d09a46ec3b964022d0b04e15c9aea1a4b4cb5f724f8b8e3885ad85f7fff56ff0`.
- App Store Connect build ID: `b511ec0b-1c53-44aa-b6b5-85bf8bcabcdb`.
- Upload succeeded September 12, 2026 at 11:49:58 Eastern.
- Destination: existing internal Margins group, seven testers and automatic Xcode-build distribution observed before upload.

## Scope and acceptance

Contains the second-edition app experience, accepted chapter/Timeline, Margin sharing, Skim speech, native-audio icon and button-feedback changes, plus the background audio-preparation callback isolation repair. The owner explicitly requested incorporating that repair, committing/pushing, and submitting internally. Earlier accepted product flows remain accepted. The corrected physical-device Live Activity/capture flow remains an internal tester recheck; upload authorization is not a claim of human validation for that fix.

Known limitation: large shared layers may still pause for about one second on first opening. Apple also reported a non-blocking missing ONNX Runtime dSYM warning (UUID `1BA1F8C6-2830-3F25-93C9-61601D46AA30`); framework crash symbolication may be limited. Upload succeeded.

## Verification

[Full release manifest](../../test-runs/20260912-111705-274440-release/manifest.json): **457 tests passed, zero failures/skips**, with fast checks passed; test execution 1375.491s. The focused crash repair additionally passed structured reconciliation of all 418 app tests, 11 adapter tests, and a physical iOS build; see [crash evidence](../../gate-1/2026-09-12-background-task-crash.md).

The earlier [iPad layout run](../../test-runs/20260912-104338-610329-ui/manifest.json) passed all 11 checks. It predates the callback-only fix and is retained as evidence for unchanged layout; it is not represented as a fresh run on this source.

Signed Release archive, generic Simulator build and App Store export passed. App and all three extensions report 0.1 (27), minimum iOS 18.0, valid signatures, `get-task-allow=false` and `beta-reports-active=true`. Evidence: `.build/release-artifacts/build-27-background-fixed/manifest.json`; archive 165.591s, generic Simulator build 119.44s, export 37.436s, upload 239.109s.

## Upgrade and tester recheck

Supports iPhone/iPad on iOS/iPadOS 18+. On-device intelligence availability depends on supported hardware/OS. Upgrade in place through TestFlight, preserving the Library, podcasts, maps, sessions and Margins. No reset is required. Seeded You Can’t Inspect the Pill is available through Reset Library and Load Sample only for a disposable test installation.

1. Play an existing podcast through headphones and allow background playback to advance.
2. Use the Live Activity microphone. Confirm current position and successful Margin recording.
3. Confirm app and Lock Screen pause/resume work. Repeat while connected to power with background preparation enabled.
4. For failure, preserve Xcode’s stopped backtrace if attached, then export Settings → Copy Privacy-Safe Diagnostics with device/OS, item/session, timing and steps. Enable device recording only for a short reproduction and turn it off afterward.

[Tester notes](what-to-test.txt). External group assignment, Beta App Review and main promotion are outside this rollout.

## Earlier attempts

[Preserved pre-upload history](build-27-pre-upload-history.md) records the canceled upload and superseded defective archives. Do not distribute anything from `.build/release-artifacts/build-27` or `build-27-accepted`; the uploaded corrected archive is in `build-27-background-fixed`.

## Distribution confirmation

App Store Connect shows Internal Group · 7 Testers · 14 Builds and Build 0.1 (27) **Testing**, uploaded September 12 at 11:50 AM. The internal triage ref and immutable TestFlight tag identify the exact uploaded source. External distribution and main are unchanged.

## Git publication status

Code and release records are committed locally. The attempted atomic push was canceled after discovering two historical diagnostic videos above GitHub’s per-file size limit. Remote branches and tags remain unchanged; [the exact blocker and proposed cleanup](git-push-blocker.md) are recorded for owner approval. Internal TestFlight distribution is complete independently of this Git publication blocker.
