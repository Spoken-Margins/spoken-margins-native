# Focused owner experience circuit — September 12, 2026

Purpose: experience implemented features whose **specific remaining cases** lack owner evidence, without replaying the accepted release checklist. This is a prepared procedure, not executed validation. All result cells remain Not tested until the product owner supplies results.

Read with the [56-issue inventory](../../../docs/pkm-issue-inventory-2026-09-12.md) and [feature clusters](../../../docs/pkm-product-plan-2026-09-12.md).

## Candidate and preparation

- Install **TestFlight 0.1 (27)** from the internal Margins group, uploaded source **`adeb923fc1d081b19dfe9d650b50ac9fb036535a`**. Do not confuse it with earlier local builds also numbered 27. [Exact upload record](../testflight-external/build-27/build-27-testflight-upload.md).
- Supported deployment: iPhone/iPad, iOS/iPadOS 18+. Use a physical iPhone and headphones for the first route. Local AI checks require eligible hardware/OS and an available on-device model. Record device, OS, app version, installation channel and date; do not invent an installed SHA from a version label.
- Automated evidence already exists: corrected-source release gate passed 457 tests, zero failures/skips, plus fast checks. That establishes verification, not these physical-device outcomes. Earlier iPad layout evidence predates the callback-only fix.
- Upgrade in place. **Do not uninstall or reset the real Library.** Keep the existing 24-scene item, shared layers, original Margins and the original nine-note session for #56 if available.
- Use the existing podcast and a disposable long native-text item with only partial audio prepared. For books use one DRM-free EPUB with two short chapters and one longer chapter, and one owned PDF with front matter plus a real outline. These are fixture requirements, not claims that such files were loaded on your phone.
- Optional existing seed: **You Can't Inspect the Pill**, through Settings → Developer tools → Reset Library and Load Sample **only on a disposable installation**. It is not a substitute for the real #56 session, partial-render case or book corpus.
- For folder export exploration, choose a dedicated `Spoken Margins Test` subfolder in a Files-visible vault. Keep test files isolated from existing notes.

Expected active attention: about **25–35 minutes**, assuming existing items and model assets are available. Imports/model generation may add machine time. Run the 15-minute timer while doing non-playback checks. Overnight and full resource matrices are separate; this circuit does not close every checkbox in every issue.

## Fast circuit

| Route | Exact actions and expected result | Scope / approximate active time | Owner result |
| --- | --- | --- | --- |
| A — Corrected background capture | Play an existing podcast through headphones, lock phone and let playback advance. Use Live Activity microphone, record a brief Margin, then resume/pause from Lock Screen and reopen app. Repeat connected to power with background preparation enabled. Expect saved current-position Margin, responsive app and transport, no freeze/crash. | Corrected post-acceptance callback repair / #74; 4 min | Not tested |
| B — Partial preparation and AirPods | On an item whose audio is still being prepared, remove/reinsert AirPod while locked; try Lock Screen and Control Center resume. Open app, Stop Generating, then use the offered preparation/retry action and resume. Expect a recoverable pause and accurate preparation state, not a dead remote control. Fully prepared playback is not this test. | #83, focused #64; 4 min | Not tested |
| C — Sleep timer, book and relaunch | Open a non-final EPUB chapter, seek near its end, select End of Chapter. Expect pause at the canonical boundary without ending the session. Resume, capture a Margin across a chapter transition, jump to an unprepared chapter, wait for its opening, then relaunch and check chapter/position. Separately arm 15 Minutes during playback, manually pause/resume and background the app; allow real wall-clock expiry. It should pause without completing the session. Test Extend and Cancel after the expiry check; process relaunch should clear a newly armed timer. | #87/#61/#64; 6–8 min active plus 15 min elapsed | Not tested |
| D — Original summary regression | Open the original nine-note session from #56, if retained. Summarize once. Judge whether listener uncertainty survives, anchors are not copied as listener prose, and the UI leaves busy state. On failure, check that retry is offered, record evidence, and stop. Do not repeatedly regenerate hoping for a pass. If original session is unavailable, mark this exact case unavailable; a new ordinary summary is only an exploration. | #56; 3 min plus inference | Not tested |
| E — PDF structure | Open the prepared owned PDF. Compare front matter and two authored headings with its visible TOC. Jump to each, listen briefly and return to the Margin anchor. Expect distinct front matter and source chapter identity; no figure-understanding claim. | #78; 3 min | Not tested |
| F — Follow suggestion | With an unfollowed eligible article or podcast, use the app normally until a suggestion appears. Dismiss it; revisit/relaunch and inspect suppression. Accept a different suggestion and inspect Following/inbox. Expect no duplicate prompt for an already-followed source and no automatic content import. If a suggestion does not occur during this circuit, mark not exercised and stop waiting; developer-seeded eligibility is the next step. | #77; 3 min, exact frequency window separate | Not tested |

For C, do not replace the active session while waiting for the 15-minute timer: that intentionally clears it. Use the interval for non-playback inspection or a break, then continue other routes. End-of-chapter does not exercise capture deferral; reserve one later timed run where a short recording straddles expiry and confirm pause is deferred until recording ends. The 30/45/60-minute choices and all background states remain a separate full matrix, not silently accepted by one 15-minute result.

Optional **3-minute baseline comparison**, not a request to revalidate accepted export: select an existing session in Margins export, choose a folder for batch Markdown output, export and open the result in Obsidian/Files. Relaunch and inspect whether the chosen folder persists. Note the manual taps and missing context. This supplies a baseline for automatic #16 delivery; **no automatic export toggle or destination-profile workflow is claimed to exist**.

## Leave running, inspect once

For #74, choose one already-imported unfinished text item, record prepared progress, enable charging preparation, plug in and lock overnight without force-quitting. The next morning record progress and try offline playback if the UI says fully prepared. No progress alone does not prove a defect because iOS chooses whether to schedule the job; record diagnostics and distinguish no launch from a failed launch. Do not call the force-quit/expiration matrix passed from one overnight success.

For #77, ordinary use across its actual suppression window is needed after the short circuit. Do not force the owner to sit through eligibility clocks or reset subscriptions solely to obtain a prompt.

## Already accepted and not in the default retest

The final [September 12 owner record](../gate-1/2026-09-12-build-27-acceptance.md) accepts the candidate after the last feedback repair. Preserve earlier accepted chapter/provenance, Skim, older-session sharing, icons and Copy with Context outcomes. Earlier GitHub comments saying “retry pending” are not sufficient reason to repeat them. A roughly one-second first-open shared-layer stall remains a known limitation; evidence of it is not a new rejection of the whole flow.

If a real regression appears, add only its shortest reproduction. Do not regenerate the accepted 24-scene map merely to inspect scrolling, share a package, or listen to existing summaries.

## Work assigned to developer evidence, not owner repetition

| Issues | Remaining evidence |
| --- | --- |
| #34 | Residual engine/dependency/configuration inventory and stale command reconciliation |
| #64/#72/#73/#74 | Chunk termination/invalidation, protected storage/eviction, foreground/background arbitration, battery/thermal/expiration measurements |
| #27/#81 | Held-out alignment corpus, negative package paths, current implementation inventory and downstream dependency reconciliation |
| #88/#89/#90 | Any specifically uncovered map eligibility, grounding, transport and resource matrix; reuse owner-accepted assets |
| #93/#97 | Frame/hitch measurements on large shared layers and cold-launch 1/3/10-add scaling; do not substitute another generic “feels good” pass |

Watch #75/#96 and historical co-op #19 are **not ready-made owner test routes**. Existing artifacts need active-lane integration first. New #16 automation, #76 OPML, #115/#116/#117/#118 and service connectors belong to feature planning, not this checklist.

## Record results and stop efficiently

For each route, use **Pass / Fail / Not tested / Unavailable**, with one sentence identifying item, step and observation. A pass accepts only the exercised case. If it crashes, loses a capture or becomes unresponsive, stop that route, preserve the Library, and continue independent routes only if the app is usable. One documented reproduction is enough; repeat after a changed build or a specific diagnosis.

Diagnostics: Settings → **Copy Privacy-Safe Diagnostics**. Enable diagnostic recording only briefly around a failure, export, then disable it. Record device/OS/build/channel/date and steps alongside diagnostics. Keep unredacted Library inventories and note content private. Store the owner's resulting acceptance notes beside this procedure; do not populate results from automated checks.

Human-validation scope excludes new feature clusters, unsupported devices, overnight guarantees, full corpus/stress matrices and any external distribution decision. No new test run, device install, account connection or human validation was performed to prepare this document.
