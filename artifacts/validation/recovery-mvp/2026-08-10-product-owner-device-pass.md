# Recovery MVP Product-Owner Device Pass

- Date: 2026-08-10
- Reporter: product owner
- Installed build number: not supplied
- Installed commit SHA: not supplied
- Device and OS: not supplied
- Diagnostics path: not supplied
- Private evidence: a 47,081-byte AI-handoff Markdown export for the native-audio item `What makes for a dream job? | Benjamin Todd` was supplied through Codex. The private export is not copied into the repository because it contains listener transcripts and source context.

## State Rules

This record preserves only the bounded product-owner results actually reported. It does not infer the installed build, commit, device, OS, or acceptance of unmentioned checks.

## Human-Validated Objectives

The product owner reported the following numbered objectives as validated:

1. Long-title library presentation and deterministic Listening Maps for structured pasted text, including predictable mapless behavior for unstructured text.
2. Opening the correct item detail from the playback item/chapter title without stopping playback.
3. Cancel and confirm behavior for Empty Recently Deleted, including the resulting empty state.
4. Starting native-audio playback from a selected publisher chapter without the prior error.
5. The bounded Live Activity/interjection path, including the accepted removal of the unreliable Live Activity play/pause affordance. The product owner requested a separate enhancement to use available playback-header space for the next chapter as a tappable skip target.
6. Generated-response playback/progress and return to the preserved native-audio position. The supplied handoff contains an AI Response and a later AI-response-targeted interjection; the product-owner report supplies the actual device acceptance.
8. The large Share Session export preview and complete export path. The product owner requested that Source Text be unavailable or visibly disabled for native-audio items.
9. Automatic final-audio session closure and cleanup.

These direct reports advance the bounded flows above to `human_validated` even though the build and device identity were not supplied. They are not evidence for a different candidate build.

## Objective 7: Partial; Not Human-Validated

The product owner reported that the generated interjection summaries were generally good, but found two defects:

- some summaries retained verbal fillers such as “uhm” and “ah”;
- a generated summary included an interjection that the product owner had deleted.

The supplied handoff supports the deleted-interjection report. Its source timeline contains eight surviving source interjections, while its Interjection Summary contains nine bullets. The unmatched first bullet begins `is a test interjection to see if it properly locates`; no corresponding surviving source-interjection entry appears in the exported timeline.

The supplied summary does not itself contain the reported “uhm” or “ah” tokens. That observation is recorded as direct product-owner device evidence rather than attributed to the attachment.

Because current-record scoping and cleanup of spoken fillers are acceptance properties of the summary flow, objective 7 and GitHub issue #56 remain not `human_validated`.

## Native-Audio Export Boundary Feedback

The product owner accepted the large-export flow but reported that Source Text should not be selectable for a native-audio item and suggested disabling or graying out the option.

The runtime already prevents full native-audio source text from being included when the option is selected; the remaining issue is that the export UI presents a misleading control. This feedback does not revoke the bounded large-preview acceptance.

## Supertonic / Issue #34

The product owner reported:

- cold latency: acceptable;
- 30-minute narration: great;
- thermal behavior: fine;
- AirPods behavior: great;
- James and Lily voice quality: great.

Those physical-device checks are now `human_validated`. The report did not explicitly cover the documented 100-chunk memory trend or interruption/reset cases, so this record does not infer those results.

## Legacy / Issue #40

The product owner reported that Safari intake works but needs a UX pass:

- selected-text intake is unnecessary;
- intake should require fewer button presses;
- both the Share extension and Safari extension occupy too much screen space and feel visually unfinished;
- a UI pass should improve feel and user efficiency.

This is partial acceptance of Safari intake functionality, not full human validation of issue #40. The report did not cover the remaining legacy speech, podcast/Now Playing, recovery, or normal/legacy isolation checks.

## App Store Screenshots / Issue #41

The product owner agreed to defer App Store screenshot work until the release UI is frozen.

## Follow-Up Boundaries

Keep the following work separate so validated flows do not silently absorb new scope:

1. Summary correctness: remove remaining filler from generated summaries and ensure deleting an interjection invalidates, regenerates, or otherwise removes its derived representation from active summaries and exports.
2. Playback-header efficiency: show the next chapter in available space as a tappable skip target without replacing the current item/chapter identity.
3. Native-audio export clarity: disable or hide Source Text for native-audio items while preserving bounded source context and listener-authored exports.
4. Share/Safari extension UX: reduce footprint and taps, remove selected-text intake if confirmed as out of scope, and preserve page/article and podcast-link intake.

## Product-Owner Result

- Objectives 1–6, 8–9: **PASS / `human_validated`** for the tested build.
- Objective 7: **PARTIAL / not `human_validated`**.
- Issue #34 stated device checks: **PASS / `human_validated`**.
- Issue #40 Safari intake: **PARTIAL**; broader validation remains open.
- Issue #41: intentionally deferred.

## Follow-Up Implementation And Automated Evidence

After recording the product-owner result, the requested follow-ups were implemented in the working tree:

- the playback header now offers the following chapter as a one-tap target;
- deleted interjections are excluded from summary candidates, eligibility, displayed derived summaries, and exports, and spoken-note cleanup removes the reported filler variants;
- Source Text remains visible but disabled for native-audio exports, with an explanation of the bounded-context boundary;
- Safari article capture now runs from one toolbar action without a selected-text mode, and the Safari and Share extension surfaces use compact status UI.

These changes are `verified`, not `human_validated`. Evidence collected on 2026-08-10:

- contract and surface-contract validators passed;
- SessionKit built successfully and its 142-test suite passed with zero failures;
- browser extraction's 8-test suite passed with zero failures;
- the full `SpokenMarginsAppTests` suite passed 175 tests with zero failures on an iPhone 16 Pro simulator running iOS 18.6;
- generic iOS Simulator builds passed for both `SpokenMarginsApp` and `SpokenMarginsLegacy`, including their Share and Safari extensions.

Only the four changed flows above require a focused product-owner recheck. The earlier bounded passes do not need to be repeated unless the next candidate differs beyond this recorded scope.
