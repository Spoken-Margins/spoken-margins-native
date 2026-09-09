# Compact presentation — #100 / #107 / #108

Development version 0.1 (26), `codex/provisional-next`, base commit `d8766c43bb0ae54ec15b3254679bba0a9378cd6e` plus the working-tree diff. This is not the distributed TestFlight 26 binary. No upload, installation on the owner's phone, or issue closure was performed.

## Scope

- Library: replace the three-level editorial header with a short heading and move the existing conditional Offline Rendering summary above onboarding and listening content. Explicitly show filter-menu titles and keep the regular-width filter row at its natural height; the iPad screenshot exposed an icon-only, vertically stretched sort menu that item-row assertions did not catch.
- Item Detail: place Listening Sessions before Chapters and shorten the resume label to Continue.
- Persistent mini-player: remove decorative artwork and the duplicate visual progress bar, retain chapter/percentage and all existing actions, stack controls at accessibility text sizes, and retain safe-area placement. VoiceOver's open action now includes item identity and progress.
- Playback: remove NOW PLAYING, tighten card spacing, and group Mix with Text, sleep timer, and speed. Use a wrapped layout where one row cannot fit. Mix retains its existing state setter, recording restriction, settings visibility rule, and enabled volume/background-audio controls; selected state has both a checkmark and an accessible value.
- Native text already opens in a separate Text sheet in this source revision. Preserve that behavior; no new inline excerpt or text projection was added.

Playback, seeking, audio policy, preparation, imports, persistence, Library filtering/sorting, gesture ownership, export routing, Skim/Live Activity styling, and Margins workflows are outside this patch. No SessionKit or app-model code changed. These are partial issue scopes, not completion of the parent redesign issues.

## Environment and reset

Supports iPhone/iPad on iOS/iPadOS 18+. Automated simulator checks use iOS 26.5. No migration or reset is needed; retain the existing Library and current session. UI automation uses its existing isolated `--ui-testing` seed, including the Pill sample and the existing text, recording, import, and accessibility fixtures. For owner review, use one existing podcast, one native-text item, an item with saved sessions and chapters, and items already present in Offline Rendering. No new user sample data is required.

Diagnostics: app Settings → Developer diagnostic export if needed. Test manifests and result bundles are listed below; `device-build.log` records the generic iOS build. Product-owner feedback belongs beside this handoff.

## Owner review checklist

All entries remain **not assessed**; automated checks do not establish human validation.

| Check | Pass/fail notes |
| --- | --- |
| Library items appear sooner; Offline Rendering remains discoverable | Not assessed |
| Sessions precede Chapters; Continue opens the same saved session | Not assessed |
| Mini-player title/progress remain legible and all four actions remain reachable | Not assessed |
| Large Dynamic Type keeps the mini-player clear of scrollable content | Not assessed |
| Player hierarchy is clearer for podcast and native text | Not assessed |
| Mix on/off is obvious; volume and background controls remain usable | Not assessed |
| Text sheet, sleep timer, rate and primary transport remain accessible | Not assessed |

## Verification and limitations

Implemented. Final fast checks and all 393 app tests passed with no skips. The final focused iPad Library route passed, and its screenshot confirms the corrected filter row and compact mini-player. Full eight-route UI plans passed on phone and tablet at the intermediate revisions described below. Final full phone UI verification remains incomplete because Xcode could not connect the test runner on either phone simulator. This is not a release-ready or human-validated claim.

Final source fingerprint: `ce4a191b3637e6dec67709135dd6376eb282842d924743a2acc08d900adee334`.

| Evidence | Result / scope |
| --- | --- |
| `artifacts/test-runs/20260909-122710-911121-fast/manifest.json` | Final fast — verified |
| `artifacts/test-runs/20260909-122854-596394-app/manifest.json` | Final app — verified, 393 passed, no failures/skips on iPad Pro 11-inch (M5), iPadOS 26.5 |
| `artifacts/test-runs/20260909-122748-491541-smoke/manifest.json` | Final iPad Library — verified; reviewed screenshot `library-ipad.png` |
| `device-build.log` | Final generic iOS device compilation — BUILD SUCCEEDED |
| `artifacts/test-runs/20260909-121755-703781-ui/manifest.json` | All 8 iPad routes passed before the final two-line Library menu-label/natural-height correction. Covers accessibility/keyboard/mini-player clearance, imports, export, real scrubber drags/continued progress and recording. Player screenshot `player-ipad.png` remains current; player code did not change afterward. |
| `artifacts/test-runs/20260909-115644-647830-ui/manifest.json` | All 8 phone routes passed before the secondary-control label/height refinement and final Library menu correction. Not final-source verification. |

The final Library change was checked with the existing focused route and screenshot instead of repeating unrelated import, export, recording and audio routes. The full final-source phone UI gate is still open. Large-text geometry passed before this last Library-only adjustment; the horizontal natural-height adjustment applies only outside the accessibility-size wrapped layout.

### Retained failures and interrupted runs

- Initial app run `20260909-115437-120761-app` failed the existing local-audio resume assertion at LocalAudioListeningPackageTests.swift:78: 210 ms observed, required greater than 312 ms. The same test passed in both later complete app runs on iPad (`20260909-121131-590075-app` and final). Timing nondeterminism remains a concern; this UI patch makes no claim to fix playback.
- Phone app runs `20260909-120544-179379-app` and `20260909-120912-479369-app` were stopped after no test session connected. A simulator restart did not resolve the launch stall; the same build executed successfully on iPad.
- Final phone UI attempt `20260909-121419-599284-ui` on the separate iPhone release-verification simulator was stopped after approximately 140 seconds without any completed tests. It is not counted as passing.
- Intermediate iPad UI attempt `20260909-120400-859320-ui` was intentionally stopped before completed tests to apply the screenshot-driven Mix/Sleep refinement. It is not counted as passing.

Each run above retains its manifest and logs under `artifacts/test-runs/`. No test expectation was weakened, skipped or deleted. Initial screenshots under `iphone-screenshots/` and `ipad-screenshots/` are intermediate evidence; use `library-ipad.png` and `player-ipad.png` for the reviewed result.
