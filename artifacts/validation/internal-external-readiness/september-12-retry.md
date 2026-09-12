# September 12 validation retry

Latest owner recheck, September 12: Skim behavior and speech speed, sharing the older session’s Margins, and native-audio Library icons are `human_validated` for the installation exercised. Copy with Context also performs the copy correctly. The owner again rejects Margin-detail tap feedback: actions execute, but there is no visible response at the button; a completion toast is insufficient. Shared-layer opening improved from roughly five seconds to roughly one second of initial hanging, but remains unresolved. Installed source identity is not independently established. The owner subsequently confirms the affected sheet says “Open Item,” identifying the intended local surface.

## Reported failures and bounded changes

- Completed-session Timeline navigation errors while a new session works. Chapter actions now start a replay session when the selected source session is finished, retaining completed history. The beginning entry deliberately starts source playback even without chapter metadata.
- Exporting an older completed session with two Margins shows zero shareable Margins when a newer empty session exists. Export count and draft preparation now read the explicit export session, independently of active playback. Item’s Export latest session explicitly selects that item’s session.
- Native audio uses the text icon except some uploaded files. Library rows now carry native-media representation information; the icon no longer relies solely on the source extension/type.
- Skim words sound muddled at accelerated speed. Code confirmed Supertonic synthesis used the selected speed. Summary synthesis now uses natural speed and AVPlayer applies listening speed with time-domain pitch handling, including live rate changes. Generated cache identity changes to natural-rate-v2 so old accelerated summaries are not reused. Reopening a native-audio/podcast item prepares missing generated summaries from the existing map; supplied authored audio is preserved. No map regeneration is required. Audible quality remains an owner check.
- Margin detail’s Open in Timeline errors when another session is active. Replaced with Open Item, using the existing browsing route and preserving playback. A scoped UI check follows this route; export remains available on the Item/session screen.
- Initial shared-layer loading is expensive. SQLite previously decoded all imported Margins for every requested layer. Reads now filter by layer before decoding, while malformed JSON retains the existing quarantine behavior. A boundary test verifies unrelated layers are neither decoded nor quarantined. This supports the change, not a measured five-second device improvement.
- Detail buttons lack pressed feedback. A dedicated ButtonStyle derives foreground/background/opacity directly from isPressed; the completion banner remains separate. The owner subsequently rejected this third attempt; this style is not accepted evidence of visible tap feedback.

## Recheck

Keep the same Library. Use the completed session with two Margins and the newer empty session. Record installed source identity, device/OS and date. Do not reuse the superseded IPA as evidence for these repairs.

| Check | Owner result |
| --- | --- |
| Tap an early/middle chapter in the completed session Timeline; starts there and retains old Margins/history | Pending |
| Export the older two-Margin session; count and outgoing selected notes are those two; newer session remains empty | `human_validated`: owner says older-session sharing works great |
| Prepared/native audio and imported audio have headphones icons; text-only items retain text icons | `human_validated`: owner accepts Library icons |
| Reopen mapped item, let revised summary audio finish preparing, listen at 1× and accelerated rate; words remain intelligible | `human_validated`: owner accepts Skim behavior and speech speed |
| From a Margin on another item, Open Item opens its detail without switching playback; selected session export is reachable | Pending |
| First opening a large shared-layer Item/Timeline is scrollable, then remains smooth during audio | Improved, unresolved: owner reports about one second of initial hanging |
| Copy/recording/retry controls visibly react while pressed; paste confirms copied content; Retry Context recovers or shows a specific failure | Failed tap feedback for third attempt. Copy execution accepted. Retry Context result not newly confirmed |

Existing accepted flows and #14 policy acceptance are retained. Publisher timestamps (#119) and any prior exception not explicitly accepted remain pending; this report does not infer their results.

## Engineering evidence

Final verification passed on the input recorded below. The first app run compiled and executed; its two new completed-session tests exposed fixture setup that mutated storage while a live engine retained an older session position. The fixtures now close that live session before seeding completed history. The session-specific two-Margin count/draft assertions passed in that initial run; failed history assertions were not counted as a pass. UI-route selection was also corrected before the final run.

Current source: uncommitted repairs based on `4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60`, local version 0.1 (27), input `5a98939c47e7f95f5091908181d00013b7be59fe14fb3d07c083ca3afa48e721`. No updated physical-device install/archive/upload is claimed. Supported deployment: iPhone/iPad iOS/iPadOS 18+; verification destination iPhone 17 Pro Simulator iOS 26.5. Intelligence features remain device/OS dependent.

- App: [final manifest](../../test-runs/20260912-090959-484362-app/manifest.json), **417 passed, zero failures/skips**, tests 64.449s.
- The second development run additionally exposed a real completed-history overwrite in `SessionEngine.endSession`; its fix is covered by the final app pass. One existing real-audio pause/resume check failed before reaching Skim and passed on its single retry; no failure was discarded or counted as success.
- GitHub retry observations recorded on #17, #68, #90, #93, #108 and #109. Their open status remains appropriate. The newer native-share-sheet success does not close session-selection sharing.

Diagnostics: Settings → Copy Privacy-Safe Diagnostics; record only a short reproduction and turn recording off afterward. Use your existing completed/two-Margin plus empty-session item. Preserve the real Library; no reset is required. Seeded text is available through Reset Library and Load Sample only on a disposable simulator. Older test/build evidence remains historical and cannot identify this updated candidate.

- Final fast/audio/UI: [manifest](../../test-runs/20260912-091143-783306-sept12-fast-audio-ui/manifest.json), verified on the same implementation input. Fast checks include 286 package tests passed, one explicitly permitted corpus skip, 11 browser tests, 10 runner tests, and validators. All **15 scoped audio/UI tests passed, zero failures/skips** (11 AudioAdapters, one SpeechCanary, and three UI routes). Shared build 46.482s; audio/UI tests 418.175s. The Open Item UI route reached Item detail and returned to playback. These tests do not establish subjective pressed feedback, voice intelligibility or a physical-device first-open frame-time improvement.
- Stopping rule reached: required development checks pass. No further unchanged-input development tests, signed archive, device install or distribution performed for this handoff.

## Fourth feedback attempt: confirmed Open Item sheet

The owner confirms “Open Item” is the affected navigation label. The new control keeps its highlighted colors for a short period after activation, independent of SwiftUI’s transient `isPressed`. It yields for 80 ms before running the action so synchronous model work or dismissal can follow a visible frame, and holds the highlight for another 350 ms after the action returns. Native Button activation still handles touch, accessibility and scroll cancellation. Repeated activation during this short interval is ignored. This changes only the action rows in the Margin sheet.

The root cause of the previous invisible transient state is not established by source inspection. The new attempt requires visual evidence from an actual short touch; a toast assertion alone is not evidence. Owner acceptance remains pending. No audio, sharing, or loading implementation is changed in this attempt.

### Fourth-attempt engineering evidence

Verified input: `924ffb51430c18341f95b31496d79e023e8a90c4b6e9620a241744a0e62d0203`, based on the same uncommitted version 0.1 (27) checkout at `4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60`. [Manifest](../../test-runs/20260912-margin-feedback/manifest.json): 417 app tests and one scoped UI test passed, no failures/skips; fast checks passed (286 package passes with the existing permitted corpus skip, browser/runner tests and validators). UI build 41.583s, UI execution including runner setup 86.376s; app build 43.552s and app test execution 65.015s. Audio checks were not repeated for this button-only change. Required checks passed once; stop verification here.

The scoped route executes a 50 ms touch on Copy with Context in the actual Margin sheet. Inspection of [recorded frames](../../test-runs/20260912-margin-feedback/tap-frames.png) shows dark background/light text for approximately 0.4 seconds, followed by normal appearance. [Short clip](../../test-runs/20260912-margin-feedback/quick-tap-feedback.gif) is cropped from the Simulator recording, not a mockup. The UI assertion still establishes action execution/banner; visual inspection of the recording separately establishes the observed highlight. This is developer verification, not physical-device or owner validation, and does not establish feedback for every accessibility input mode.

Recheck only the affected action rows on the next local install: quickly tap Copy with Context and confirm the button itself visibly changes; check Play/Stop Recording and Open Item similarly. Retain the existing Library. No new phone installation, archive, commit or upload was performed. Existing accepted Skim/sharing/icons flows need no repeated acceptance for this patch. Other unresolved checklist rows remain open.
