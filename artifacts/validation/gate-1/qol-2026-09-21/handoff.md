# QoL repair candidate — September 21, 2026

Status: implemented with verification results below; this is not owner acceptance.

## Identity and boundaries

Branch `codex/provisional-next`, base commit `47f9d2f69e9e44a5bb3e684451c77c58bc813ba3`, plus uncommitted repairs. Build configuration remains 0.1 (27); exact dirty-source hashes are in the test manifests. The owner's separate 0.1 (28) archive was found and preserved; see `archive-identity.md`. No commit, upload, physical-device install, or baseline advancement.

Supported app baseline: iPhone/iPad, iOS/iPadOS 26 and later. Current simulator verification uses iPhone 17 Pro / iOS 26.5. iOS 27 speech remains blocked by the prior documented Apple simulator XPC/AppIntents service failure; no unchanged retry is used as evidence of repair.

## Changes to exercise

- Margins groups notes by item, with one Share button opening that item's existing export screen and listening-session picker. This follows the owner's correction; individual Margins have no share action. Export Sessions remains on Margins and now returns there.
- Add Text labels and outlines the editor, offers Paste & Add, derives an untitled item's name from opening words, and retains manual editing. Explicit HTML clipboard headings, Markdown bold headings, and Setext headings are retained for authored chapter navigation.
- Following shows followed feeds before the inbox. Manage exposes Mute/Unfollow; Unfollow confirms and retains Library items.
- Mark Complete keeps Undo available for ten seconds; later completions cannot be dismissed by an older timer.
- Finished playback offers Add a Margin and Share.
- Next chapter advances to a real authored boundary, falling back to generated scenes for media without publisher chapters. It is absent when unavailable. Timeline identifies the active entry with a text/icon cue and subtle background, preserving provenance.
- PDF import excludes a sufficiently evidenced bibliography tail. Bracketed numeric citations and explicit footnotes receive spoken labels; defanged domain names receive explicit separator pronunciation with source-offset mapping. Prepared-speech normalization identity advances to prevent stale audio reuse.

## Evidence boundaries and known limits

- Plain parenthetical numbers such as `(17)` remain unchanged because citation intent cannot be inferred safely from punctuation alone. #138 is therefore partial, not complete.
- Bibliography detection is conservative and affects new PDF imports. Existing Library text and anchors are not rewritten; reimport a PDF as a separate item to compare.
- Rich clipboard headings require explicit HTML heading tags matching the plain text, or explicit Markdown/Setext headings. Pure visual styling without semantic structure is not guessed.
- #122's physical-device memory termination, and device responsiveness reports #93/#131, require representative device evidence. Simulator RSS is supplemental and is not a device physical-footprint measurement.
- Only the owner validates experience. #90, #119, and #17 were closed based on the owner's explicit report; see `owner-acceptance.md`. #68/#115/#116 stay open for owner review.

## Reset, sample data, diagnostics

Automated UI routes use the dedicated Release Verification simulator and `--ui-testing` seeded samples. Do not use Reset Library on an owner installation. Test relaunches seed their own synthetic Library. Recordings contain synthetic examples, including item-pill and the exact emoji article speech regression. Use Add Text with two Markdown headings and paragraphs to exercise intake and next-chapter navigation on an owner installation; keep it as a separate sample item.

Raw test results, test input hashes, logs, and xcresults live under `artifacts/test-runs/`. Feature videos live in `recordings/`; `recordings/index.json` maps each recording to its UI test and outcome. App diagnostics remain available in Settings. `simulator-memory.json` records simulator RSS when present.

## Owner checklist

| Flow | Owner pass/fail notes |
|---|---|
| Share an item's Margins, select the intended listening session, review and share | Pending |
| Export Sessions from Margins and return | Pending |
| Paste & Add / manual editing / empty clipboard / readable automatic title | Pending |
| Followed-feed Manage, cancel and confirm Unfollow; Settings opens | Pending |
| Mark Complete, Undo, repeated completion, notice expiry | Pending |
| Finish, add a final Margin, return and Share | Pending |
| Next chapter and active Timeline entry on text and podcast | Pending |
| Mixed Timeline provenance (#68), including opening shared Margin detail | Pending |
| Skim destination preview (#115) matches its landing | Pending |
| Prepared frontier (#116) is distinct from playback and survives reopening | Pending |
| Bibliography-heavy PDF reimport and speech clarity | Pending |
| Device memory and Settings/Library scrolling during rendering | Pending |

## Verification results

- Full first release run: **496 passed, 1 failed, 0 skipped**; the sole failure was Add Text keyboard overlap at maximum accessibility size. Raw manifest: `artifacts/test-runs/20260921-190625-514869-release/manifest.json`.
- Corrected-source fast suite passed: `artifacts/test-runs/qol-20260921-fast-final/manifest.json`.
- Corrected-source app suite passed after bounded test-startup recovery: `artifacts/test-runs/qol-20260921-app-recovery/manifest.json`. The interrupted zero-test startup remains a failed/incomplete run, not passing evidence.
- Final outcomes are recorded in `verification-summary.json`.
- fast-final: verified [{'passed': 306, 'failed': 0, 'skipped': 1}]
- app-recovery: verified [{'passed': 455, 'failed': 0, 'skipped': 0}]
- phone-ui-final: verified [{'passed': 15, 'failed': 0, 'skipped': 0}]
- ipad-ui-final: verified [{'passed': 15, 'failed': 0, 'skipped': 0}]
- Device build: passed.

## Remaining evidence gaps

No new owner acceptance is inferred. Plain parenthetical PDF citations remain unresolved (#138 partial). Physical-device memory/performance claims remain open. There is no dedicated Skim-preview visual recording for #115, nor a separate recorded walkthrough of Paste & Add, Unfollow confirmation, or the finished Add-a-Margin flow. Unit coverage and the available route recordings are listed separately; these omissions are not passing UI evidence. Model work was bounded when the shared account reached 91% remaining to preserve the owner’s 90% floor.
