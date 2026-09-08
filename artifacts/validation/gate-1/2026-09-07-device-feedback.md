# Product-owner device feedback — September 7, 2026

Source: direct product-owner messages and the attached privacy-safe diagnostic export, exported 2026-09-07T20:51:29Z. The connected phone reports developer-installed Spoken Margins 0.1 (25). Exact installed source SHA is not present in the export and is not established by its bundle version. Current checkout at the start of remediation: `8f5b74c`, `codex/provisional-next`. These observations describe the tested device build, not acceptance of subsequent edits.

## Owner observations

| Report | State | Scope / limitation |
|---|---|---|
| Mark completed / in progress | human_validated | Owner says the controls are great. Continue Listening removal and swipe navigation failed separately. Relaunch persistence was not explicitly reported. |
| Stop / Retry | human_validated | Owner says it works now; every paused/AI target variant was not separately reported. |
| Following | human_validated | Owner says it looks to work; stale asynchronous candidate stress remains a separate check. |
| Prepared source replay | human_validated | Smooth replay accepted. The remaining Stop button is an affordance defect. |
| Feed text/audio metadata | human_validated | Correct metadata accepted. Native text import during playback failed separately. |
| Quick Add drawer | human_validated | Very responsive. Source-list native text import animation still stutters. |
| Browser plug-in import | human_validated | Owner says it works; this does not establish every Safari PDF route. |
| Single Library item accessibility | failed | Mini-player covers the only item, preventing selection. |
| Native text import during live text playback | failed | Animation stutters, audible playback stops, button still indicates playing. |
| Prepared and live text scrubbing | failed | Seek moves playback but indicator dislocates/freezes. Leaving and reopening repairs its visible position. |
| Startup preparation | failed | One imported native text item remained loading at least five minutes during fully rendered playback. |
| Continue Listening completion | failed | Marked-complete item stays showcased; a rightward completion swipe opens details. |
| Mid-playback voice continuity | failed | Native text unexpectedly falls back to the assistive/system voice halfway through playback. |

## Diagnostic evidence and inference limits

The export reports two startup jobs at `preparing_0_of_2`, on-device generation `rendering` at 13/85 chunks, playback `playing`, target `item_text_tts`, 114 Library items, and background preparation `expired`. It predates the reported fallback and contains no fallback reason. Thus it does not prove a specific timeout, thermal event, or renderer error caused that occurrence.

The owner explicitly reports smooth UI while Supertonic produces audio at roughly twice listening speed. Generic CPU contention is not an established explanation. Investigate renderer scheduling, main-thread import work, client replacement, and UI gesture ownership independently.

## App Store Connect reconciliation

Read-only inspection of the signed-in Chrome [Spoken Margins build list](https://appstoreconnect.apple.com/teams/e6c69191-84a0-4c60-a714-a2475ac42c17/apps/6792790885/testflight/ios) shows newest upload 0.1 (25), Complete, assigned to internal Margins, with no Build 26 listed. Build 21 is Testing and assigned to External Beta as well as Margins; Build 19 is also Testing in both groups. The existing Build 21 upload handoff identifies source `6a96b870715963bf2055e36efdb0dfb93b134067`; its project settings confirm build 21 and it is an ancestor of `main`. The local tag `testflight/0.1-build-21` now preserves that recorded source, and release-lanes.md reflects the already-existing external distribution. No distribution settings or remote refs were changed.

## Remediation acceptance boundary

Subsequent implementation and automated results belong in the remediation review. Recheck the failed device flows on an identified candidate. Preserve the existing Library; no device reset or reinstall has been performed by this task. Export diagnostics immediately after any recurrence, including the fallback reason when present. Existing positive observations remain bounded acceptance, not a blanket release approval. Issue #14 remains a separate gate.
