# Build 27 internal TestFlight handoff

Status: release preparation in progress; not yet uploaded.

- Accepted and intended uploaded source: `39e8b4ecf7453ab1f643b4df7f9b02a1640a0d52`, `codex/provisional-next`.
- Version 0.1 (27), bundle `com.spokenmargins.native`, team `J8SWC6J3VY`.
- Implementation input: `924ffb51430c18341f95b31496d79e023e8a90c4b6e9620a241744a0e62d0203`.
- Owner acceptance: [September 12 release decision](../../gate-1/2026-09-12-build-27-acceptance.md). The owner reports “validated” and authorizes internal distribution. This supersedes the prior pending final-feedback check for the accepted candidate.
- Destination: existing internal Margins group, seven testers, automatic distribution for Xcode builds verified in App Store Connect on September 12.
- Deployment: iPhone/iPad, iOS/iPadOS 18+. Local intelligence availability remains dependent on supported hardware and OS. Simulator release destination is iPhone 17 Pro on iOS 26.5; tablet checks use iPad Pro 11-inch M5 on iPadOS 26.5.

## Scope and known issues

Build 27 includes the second-edition app experience and subsequent accepted fixes to source import, chapters/listening maps, Margin/session export, completed-session playback, Skim speech, native-audio icons, imported-Margin loading, and button feedback. The final button feedback change is included in the accepted commit.

The owner previously observed about one second of initial shared-layer opening delay, improved from about five seconds. Retain this as a known issue, not a claim of zero loading latency. No new product work, tester membership changes, or external group assignment is included in this internal rollout.

## Upgrade and diagnostics

Upgrade in place through TestFlight; no Library reset is needed. Preserve the existing Dwarkesh item, generated map, completed sessions and shared Margins. On a disposable Simulator only, Reset Library and Load Sample provides seeded text including You Can’t Inspect the Pill. Do not reset the owner’s real Library.

For a failure use Settings → Copy Privacy-Safe Diagnostics. Record Build 27, device/OS, affected item/session and reproduction steps. Enable device diagnostic recording only for a short reproduction, then disable it. Avoid publishing private source content or credentials.

## Release checklist

- [x] Product owner reports validation accepted and requests internal distribution.
- [x] Live App Store Connect confirms Build 27 is still available before upload.
- [ ] Exact-source release and iPad checks pass.
- [ ] Signed archive/export and bundle identities verified.
- [ ] Upload succeeds and Apple processing completes.
- [ ] Margins group shows Build 27 Testing.
- [ ] Exact uploaded source tagged and internal triage lane advanced.

Old Build 27 archives in `.build/release-artifacts/build-27` are superseded and must not be uploaded. This release uses `.build/release-artifacts/build-27-accepted`.

## Release-test label correction

The full release run executed 456 cases: 455 passed and one failed because the seeded Timeline UI test still searched for the former “Source” provenance label. The accepted app calls it “Chapter.” Only that test assertion is updated; application/runtime sources remain identical to the owner-accepted commit. The failed run is retained at `artifacts/test-runs/20260912-101555-725995-release/manifest.json`. The focused correction and coverage reconciliation are recorded separately; the original run is not relabeled as passing.

The corrected route passed on a clean Simulator installation; the first focused attempt was blocked by the preceding written-Margin test’s retained Library instead of its expected seeded item. Both attempts are retained. Final focused manifest: `artifacts/test-runs/20260912-build27-source-label-fresh/manifest.json`; combined coverage accounts for all 456 expected release cases. Fast checks also passed. The test-only assertion changes the full verification input to `52977e48f630caf4ff4dd2cd47cb2c068e5a98d7884c0613c1524ad15b4cb5c4`; runtime is unchanged from the accepted source. iPad verification and archive remain pending at this point.
