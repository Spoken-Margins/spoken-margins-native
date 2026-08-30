# Build 23 automated verification

Status: Build 23 is `implemented` and automated-`verified` at the runtime
candidate below. It is not `human_validated`; only the product owner can advance
that state after exercising the physical-device handoff.

## Candidate

- Version/build: Spoken Margins 0.1 (23)
- Branch: `codex/build-23-release`
- Runtime SHA: `10f7fd192f59f1fc8dc024d6defda2c2f41b7693`
- Frozen kickoff: `build-23-ultra-seam-freeze` at
  `4e87dcb5161eda1507e44be4cb6aa61cb357b630`
- Supported deployment: iPhone and iPad on iOS/iPadOS 18.0 or later
- Automated evidence date: 2026-08-30
- Physical-device/product-owner result: Pending

The runtime SHA identifies the source used for every final check below. A later
documentation-only commit records these results without redefining the tested
runtime candidate.

## Integration topology and audits

The clean frozen worktree was divided among exactly three named, non-overlapping
gates. The steward reviewed and committed their work in the packet's required
sender, recipient, polish order, then performed root/model wiring:

1. Sender: `5777e4f`; focused verification repair: `13db95b`.
2. Recipient: `96f2909`; focused visibility repair: `37dac54`.
3. Experience polish: `820313c`.
4. Steward integration: `10f7fd1`.

The ownership audit found no shared gate edits, forbidden gate edits, duplicate
symbols, backend requests, shared-vocabulary additions, contract/schema/fixture
changes, or executable-trace changes. No Watch runtime, co-op reply, account,
hosted-storage, remote-revoke, or AI-synthesis surface entered the diff. Frozen
source tips did not advance.

The steward instantiated one app model and one sharing coordinator, wired the
new sender and recipient hosts, kept the verified package alive across the Add
Source route, resumed the pending import on return, and displayed the imported
layer in Item detail and Timeline. Import does not invoke playback and does not
change source ownership.

`xcodegen generate` ran exactly once. `project.yml` and both
`Package.resolved` files remained unchanged. The generated project change only
registered the new Build 23 app and test files.

## Verification ladder

| Check | Result |
| --- | --- |
| `./scripts/bootstrap-python-tools.sh` | Pass |
| `.venv/bin/python scripts/validate-contracts.py` | Pass; 22 Supertonic contract files validated |
| `.venv/bin/python scripts/validate-surface-contracts.py` | Pass |
| `swift test --package-path Packages/SessionKit` | 220 executed, 219 passed, 1 intentional skip, 0 failed |
| Focused Build 23 app-test gate | 18 passed, 0 failed |
| Generic iOS Simulator build | Pass |
| Generic iOS device build | Pass |
| Sender scoped UI route | 1 passed, 0 failed; 85.619 seconds |
| Recipient scoped UI route | 1 passed, 0 failed; 55.711 seconds |
| Accessibility/layout scoped UI route | 1 passed, 0 failed; 71.655 seconds |
| `git diff --check` | Pass |

The focused app gate comprises six sender presentation tests, five recipient
presentation tests, five experience-polish layout tests, and two frozen-seam
tests. The SessionKit skip is
`testHeldOutPublicDomainPodcastAnchorCorpus`; its test requires the separate
podcast-anchor benchmark runner, so it is not counted as a pass.

Both generic builds emitted only the pre-existing AVFoundation chapter-loading
deprecation warnings in `LocalSourceImporters.swift`. Intermittent
`DebuggerLLDB.DebuggerVersionStore.StoreError` host-tooling messages did not
terminate the app or fail a test.

## Scoped UI evidence

| Route | Evidence |
| --- | --- |
| Sender | Exercises Select, Review, Recipient Preview, and Share; builds a preview from the written archive; mutates package-affecting acoustic-evidence state; observes return to Review and removal of share readiness; rebuilds; presents the native system activity surface from the verified file. |
| Recipient | Uses a recipient-supplied text package with a first source miss; shows integrity-checked/unsigned disclosure; routes to Add Source; returns to the same staged package; explicitly imports; confirms playback remains stopped; finds the separate Shared Margins provenance surface in both Item detail and Timeline. |
| Layout/accessibility | Runs at the largest accessibility Dynamic Type category with darker system colors and reduced motion; confirms Library controls remain operable, Add Source's final action clears its container, and Timeline content clears the persistent mini-player. |

Result bundles:

- Focused app tests:
  `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.30_16-35-43--0500.xcresult`
- Sender UI route:
  `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.30_16-06-24--0500.xcresult`
- Recipient UI route:
  `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.30_16-26-05--0500.xcresult`
- Accessibility/layout UI route:
  `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.30_16-27-42--0500.xcresult`

## Falsification and omission audit

Automated checks directly falsify these prior failure modes:

- a recipient preview or share URL appearing before archive verification;
- a package-affecting sender mutation leaving stale preview bytes shareable;
- Select owning the dense Review editor or more than one detailed editor being
  expanded;
- a link-backed item showing or requiring a linkless payload-rights assertion;
- missing-source import becoming confirmable before reconciliation or losing
  its staged package across Add Source;
- import presenting autoplay as a consequence;
- default reveal behavior differing from Companion;
- imported provenance relying on color without a stable label and symbol;
- compact-width, accessibility-text, Add Source, or mini-player clearance
  calculations collapsing to zero or clipping in the scoped route.

Covered alternatives include link-backed reference transport,
recipient-supplied text, explicit star-versus-Include semantics, voice/text
representation selection, bounded batch preparation presentation, exact archive
round-trip, stale invalidation, missing-source return, and large Dynamic Type.

The following omission checks remain product-owner/device work because the
simulator evidence cannot establish them: real microphones and audio routes;
actual system share destinations and Files imports; real PDF/EPUB source
reconciliation; podcast reference/download and cross-edition placement;
ambiguous/unresolved acoustic anchors; VoiceOver qualitative order; iPad
product fit; dark/light visual fit; no-network behavior; real-scale bulk
cancellation/fallback; and authenticated Live Activity controls. App-authored
text and rights-confirmed embedded text retain the verified source-lane coverage
recorded in the sharing handoff and need confirmation on this exact candidate.

## Stopping rules and residual blockers

- Build 22 remains a separate pending product-owner gate. A rejected or
  undecided #84 seek result stops Build 23 distribution.
- Issue #14 remains unresolved and blocks externally enabled sharing.
- Any wrong confident podcast placement, stale or different shared archive,
  autoplay on import, source-ownership mutation, color-only provenance,
  duplicate imported layer, or upgrade library loss stops acceptance.
- Physical-device checks remain pending; automated success does not change the
  candidate to `human_validated`.

The product-owner procedure and empty pass/fail record are in
[`product-owner-handoff.md`](product-owner-handoff.md).
