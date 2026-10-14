# Solid Ground: phone validation with evidence

Prepared 2026-10-14 for the session after #1101 releases the phone. This is an operator's protocol, supporting the rolling phone build (#384). It is not a record of tests already run or a replacement for the daily combined owner plan.

## What this test can establish

Use the installed app, a few deliberately created test Margins, the owner's ears and physical headphone commands, and bounded diagnostic captures. Automate collection and comparison on the Mac. Drive ordinary controls through an established phone-control surface when available; otherwise the owner performs the numbered steps. A cable alone does not establish UI-control access.

Keep five things separate:

| Layer | Evidence / constraint |
| --- | --- |
| Resource | One owner phone and its real Library; #1101 has exclusive priority. |
| Execution | Guided actions on the normal app; isolated host/app tests for fault injection. |
| Target | Exact installed build and source item/target/session/recording identity. |
| Observation | UI, audible output, physical command, diagnostic events, persisted files. |
| Decision | Per-case PASS, FAIL, BLOCKED or INCONCLUSIVE, with owner acceptance separate. |

XCTest can drive an installed app on a physical device ([Apple UI automation](https://developer.apple.com/documentation/XCUIAutomation/recording-ui-automation-for-testing)). **Do not run this repository's existing seeded UI journeys on the owner's installation.** `UITestingLaunchSeedWriter.write` calls `store.reset()`, and stand-in audio can replace the real microphone. A new device harness would need an independently reviewed, non-seeding launch path. It is not necessary for this first evidence session.

## Release and build gate — operator only

1. Read **Claim and finish issue 1101** and #1101 live. Require an explicit release of the phone by that session or the owner. An idle chat, disconnected phone, or merged PR is not a release. Until then: no device queries, copies, installs, launches, mirroring, debugger attachment, simulator boots, or Instruments recording for this protocol.
2. Preserve #1101's evidence before changing diagnostics. Record its final installed build and unfinished reproduction state. Do not interrupt an in-progress recording, render or trace.
3. Read Settings > Version on the phone and record the full version/build/commit. Match the diagnostic `developerBuild` / capture `build`. A local checkout or `installed.txt` alone does not prove what is running. Resolve that commit and check the relevant fixes and later reverts at that commit. Refresh issue bodies, comments, labels, PR heads, checks, latest lane/audit reports and merge state; earlier PASS comments do not prove a changed head.
4. Reuse that build if it contains the required fixes. If it does not, prepare one rolling build after the release and install over the existing app through the established installer. Do not downgrade, uninstall, reset the Library, upload TestFlight, or silently switch off Mix with Other Audio. Record any setting change and restore it afterwards.
5. Pause ordinary listening first. Use a new, clearly titled `Validation <date>` text item and test recordings, plus an available podcast. Preserve all original items and recordings. Destructive tests below require an isolated test installation or explicit approval of the exact disposable records.

## Inventory and omission check

The live review found **17 open issues labelled `status: needs-human-validation`** in Solid Ground. #1101 is separately owned. #1475 is an additional coverage item: it had no human-validation label, but its redesign re-land #1551 merged as `6bb0010` on 2026-10-14. Include the new screen when that commit is installed; do not ask the owner to reconfirm the already-accepted restoration of the old screen.

All merged fix PRs below were checked against preparation baseline `6bb0010deb7b2b3fb00fefc9e7b9db3f1d0bac74`. This is source availability, **not installed-build or phone-pass evidence**. #1554 is closed/superseded; #1552 is the build-plan fix that actually merged. #1144's later spoken-intro adjustment was still being worked on in its latest issue comment; inspect its eventual PR before including that expectation.

| Issue | Fix PR(s) | Necessary proof | Case |
| --- | --- | --- | --- |
| #1506 Bluetooth capture delay | #1526, measurement only | Per-capture timing and actual first words, built-in vs headphone microphone | A |
| #1030 headphone command ends capture | #1596, beyond earlier coordinator-only changes | Physical click delivered while recording, one saved Margin with faint words | A |
| #1538 own Margin returns to source | #1590 | Audible natural completion, source resumes; paused/stopped controls stay paused | B |
| #1577 Play this moment | #1591 | Visible countdown and actual Margin voice; distinguish media anchor from text anchor | B |
| #1578 text after edition switch | #1581 | Proven switch to prepared media, then Text opens at current sentence | B |
| #1036 new session ends moment | #1236 | A Margin voice is already playing, then same-item new session stops it | B |
| #1192 notes-folder repeated work | #1222 | Unchanged interval, incremental write, timings and file hashes, not event silence alone | C |
| #1059 page title corruption | #1077 | Real Safari markdown import, title equality and repeat-import identity | D |
| #1144 bogus PDF chapters | #1539 + #1562 | Exact PDF through Safari Share and Files; chapter list and body navigation | D |
| #138 spoken numeric citations | #1188 | Fresh numbered-reference PDF, citation suppression and ordinary-number controls | D |
| #951 recording interrupted before Save | #1534 | Actual process death, preserved draft/audio, truthful recovery exactly once | E |
| #1031 calibration swallows speech | #1070 | Exact level sequence through the coordinator; live app path is not wired here | F |
| #1051 private feed variants | #1066 | Variant table, canonical HTTPS request and private classification without token disclosure | F |
| #1107 memory backoff never resumes | #1165 | Controlled warning, bounded wait, automatic progress, cancellation control | F |
| #1466 quarantine survives delete | #1481 | Real isolated SQLite/files, deleted and unrelated rows, reopen with decodable payloads | F |
| #1469 late summary failure | #1540 | Independently held A/B requests, persisted job ownership, truthful recovery UI | F |
| #1545 reverted fixes in build notes | #1552 | Generate against known reverted and re-landed commits, compare included checks | F |
| #1475 new Now screen (additional) | #1551 | Actual phone layout on article and podcast, all three panes, owner usability | B |

At execution, repeat `gh issue list --milestone 'Solid Ground' --state open --limit 200 --json number,title,labels` and compare every number with this table. Check unlabelled `found-on-phone` issues as well. Do not silently expand to Later or Co-op Experience. Do not remove validation labels or call anything `human_validated` from an automated result.

## Evidence capture — operator does this, not the owner

Create a new ignored `artifacts/solid-ground-validation/<run>/` folder. Save a manifest with phone model/iOS, installed build, source revision, case ID, UTC start/end, headphones and firmware if known, playback/input route, voice/rate, Mix setting, test item and capture IDs, preconditions, actions, expected/actual result, evidence paths, and remaining limits. Do not put private feed tokens in it. Save a separate observation for each repetition.

1. After release, copy the existing baseline before enabling anything. The two allowlisted app-container files are:
   - `Library/Caches/DeveloperDiagnostics/playback-events.json`: automatic history, bounded to 300 events.
   - `Library/Caches/DeveloperDiagnostics/latest.json`: optional detailed recording, bounded to 1,200 events; it can be absent or from an older run.
2. For a short case, Settings > Developer > **Record Detailed Device Diagnostics** on, perform the case, turn it off to flush, then **Share Diagnostics**. Confirm the actual Settings grouping on the installed build. Keep the exported JSON locally. Starting detailed recording clears its earlier detailed buffer. It is off after restart. Preserve a copy before doing either.
3. Copy both files at each case boundary, using unique destinations. Example (after release only):

   ```sh
   xcrun devicectl device copy from --device "$VALIDATION_DEVICE" \
     --domain-type appDataContainer --domain-identifier com.spokenmargins.native \
     --source Library/Caches/DeveloperDiagnostics/playback-events.json \
     --destination "$VALIDATION_RUN/A-after-playback-events.json"
   ```

4. Retain raw evidence. Parse both the direct capture schema and Share Diagnostics' JSON-string fields `playbackEvents` and `developerRecording`. Deduplicate overlapping events. Filter by UTC window plus capture/item/session identity. `elapsedMs` restarts with a process and is not a cross-launch clock. Compare the first/last retained events to the scenario; a full ring buffer or missing start means incomplete evidence, not PASS.
5. Keep short detailed runs (normally 1–3 minutes); capture separately around long intervals. Basic history omits `sample`, `preparation.*`, `scrub.*` and `main.delayed`. It cannot alone prove preparation progress. Detailed sampling is every 500 ms; a quiet log is not continuous observation.
6. Use screenshots for controls and displayed text. Preserve audible observations separately: advancing time, a waveform, transcription or an app's “playing” flag cannot prove the correct sound reached the headphones. An agent cannot listen. Save test audio only when needed and approved, locally.

The local preparation kit provides an optional copy/summary helper. The commands above remain the durable collection interface. The helper must default to offline processing and require an explicit #1101-release acknowledgement before any device call. It does not install, launch, seed, change settings, inject faults or assign PASS.

Prefer an unattached run first. Attach Instruments/Time Profiler only to investigate a reproduced timing problem, after preserving baseline evidence. A debugger/profiler can change timing and lifecycle behavior. Re-run the affected case without it before acceptance. No system-wide diagnostics or full Library export is needed by default.

## Combined phone walkthrough

Estimated owner participation: 15–25 minutes, plus a passive 5-minute notes check; PDF preparation may add time. These are planning estimates, not measured run times. The operator prepares content and handles all files and logs. Split at case boundaries if the owner wants a shorter session. Do not force every issue into ten minutes by dropping its evidence.

### A. Capture once, measure both latency and headphone completion

1. Start the test article with the normal on-device voice. With Bluetooth headphones on, tap **Add a Margin** and immediately say: **“First word amber. This is capture one.”** Speak softly but audibly for 5–10 seconds. Press the headphone's normal play/pause control **once**. Verify recording ends, exactly one new Margin appears, and the source resumes. Play the saved Margin and report whether “First word amber” is complete.
2. Repeat three times on the article and three times on a podcast. Record which was first after a route change versus a repeat. Leave at least one second between remote presses. Test skip-forward once separately if that physical control is available; play/pause success does not prove skip-forward. AirPods next-track/double-click is not the fixed command path.
3. Disconnect headphones, use the built-in microphone, and repeat three Add-a-Margin captures with **Save & resume**. Reconnect the headphones afterwards. This is a within-build route comparison, not a before/after proof of an optimization.
4. Preserve per-capture `captureID`, `tapSource`, `tapAt`, `tapToRecorderRequestedMs`, `tapToRecorderStartedMs`, `tapToFirstAudioObservedMs`, `tapToFirstNonSilentObservedMs`, input routes, and `margin.capture.health` / `.final`. Require `tapSource=app_tap` for tap latency. Pair the actual physical action with `transport.request` and `transport.ends_margin`, save outcome, count and audible words. If no remote event arrives, distinguish delivery failure from a save failure; do not substitute a screen tap and call the headphone test passed.
5. Report individual samples, median and maximum by route and first/repeat state. Recorder request delay is app-side evidence; requested-to-started includes session/route work but **does not by itself prove that all of it is iOS profile switching**. These first-audio timings are recorder-clock/meter polling upper bounds; non-silent input can be noise. `tapToStartToneFinishedMs=not_applicable` is correct for Add a Margin, which has no start tone.

The owner's 2026-10-13 choice was **headphone mic**. Keep it. #1526 added timing, not a speed fix. Under-one-second is the original desired outcome, not a claim already met. Any avoidable delay gets measured follow-up; accepting unavoidable delay remains the owner's decision. With Mix with Other Audio on, Now Playing is disabled by design: record that condition and do not call absent headphone commands a new regression of #1596.

### B. Reuse those Margins to check playback, text and session boundaries

1. While the source plays, open **Timeline**, open the saved Margin, and play its own recording to natural completion. Hear the source resume at its prior place. Repeat once with the source paused first; it must stay paused. Stop a Margin manually once; that must not unexpectedly resume the source. Cover both article and podcast (#1538, J3).
2. On a podcast Margin more than eight seconds into the source, tap **Play this moment**. Observe **Your Margin in 0:08** counting down, then hear that specific Margin. Measure source-clock lead-in separately from wall-clock buffering. Near the start of an item the lead-in may be shorter. Repeat on a text item with prepared audio and on a live text-only item. Record anchor type and whether the target switched; podcast success cannot waive a text-anchor failure (#1577).
3. After a confirmed switch from live text to prepared media, open **More > Text**. It must still exist and open at the sentence being heard. Move to another passage and repeat. Capture `targetType=transcript_backed_media`, target identity and mapped text offset in Share Diagnostics plus a screenshot. If no edition switch happened, mark this case BLOCKED, not PASS (#1578).
4. Start **Play this moment** again. **Wait until the Margin voice is actually audible**, then open that item's page and tap **Start New Session**. The old voice and countdown/card must end, with no delayed old-source resume. Observe for at least the remaining recording duration plus five seconds. Repeat the select-item/session-creation path under the precondition in #1036; selecting the same active session is not that path. If the Margin never played, stop this branch and record #1577 as the blocker.
5. On the article and the podcast, switch **Now**, **Timeline**, **Margins**. Capture all six screens. Controls should remain usable at the bottom with content above and no blank pane. For a build containing #1551, compare the dock to the owner's roughly 40% 6.1-inch direction and ask for usability acceptance. A larger phone cannot prove iPhone SE fit; that remains Test Desk evidence (#1475).

### C. Notes-folder cost during otherwise normal listening

Use the owner's already-enabled notes destination without changing it. If it is off, defer the real-library case; use a disposable destination only with its own authorization. Record library/session/note counts without exporting their text.

After the initial repair pass settles, leave the app listening in the foreground for five minutes without edits. Record destination file names as local identifiers, sizes, mtimes and hashes before/after; avoid reading contents into logs. Then save one test Margin, allow its delivery, and wait another minute. Check one expected note is created/updated and unchanged notes retain hashes/mtimes. Keep the initial/full repair separate: repair on launch, folder change or the 30-minute boundary is expected.

Inspect `automaticMarginGather` and `marginOutput.gather` duration/session/note fields, plus Time Profiler only if work persists. The event is emitted only for passes ≥500 ms. **No such events does not prove no work.** Require file evidence and the controlled incremental-gather test; if counters or continuous timing are missing, report the measurement limit. Compare with the original 37 passes / 142 seconds in 18 minutes only after normalizing duration, library size and repair boundaries. Five minutes cannot establish battery life or the 30-minute repair behavior (#1192).

### D. Import checks with known input, not a convenient substitute

1. #1059: prepare four Safari pages whose exact titles are `Why I left Google. Part 2`, `Notes on v1.5 release`, `A//B testing. Part 2`, and `Ann Lee on X: "Hello there"`. Their extracted markdown must have no heading/front-matter title, which would mask the old bug. Use the actual Safari extension import, compare full title strings, and repeat each import to check stable item identity/no duplicates. A `.md` Files import is a separate control and should still drop `.md` from a filename. Retain source HTML/hash and extension payload locally; screenshots with truncated titles alone are insufficient. Do not publish fixtures; use an approved local test server or an existing controlled page.
2. #1144: use the exact [CASP intelligence-explosion PDF](https://casp.ac/__l5e/assets-v1/5efd4b41-deb5-4513-a0a3-b4f82d2b79ea/intelligence-explosion.pdf) identified in #1539/#1562. Record its SHA-256. Import a fresh copy via Safari **Share > Spoken Margins**, then test Files separately without deleting an existing owner item. Record duplicate handling if it reuses that item; that is not a second fresh-extraction proof. Capture the full chapter list: the desk's reference is ten chapters, Abstract, Introduction … Notes, with the wrapped “Automating AI R&D could trigger an intelligence explosion” as one chapter around 13%, and none of the five title fragments. Jump to first, middle and last body passages and confirm text and audio. Do not count 0% on a new session as a failure. The exact PDF is not committed; if unavailable, report BLOCKED, not success with a generated facsimile.
3. #138: use a fresh import from the existing C1 numbered-reference corpus, with marked examples `(17)` and `(3–5, 8)`. Compare heard text to expected prose in both live narration and a prepared edition. Ordinary `(1)` / `(2)` list items and `95% CI` must remain. An old v1 imported item deliberately retains its text and cannot qualify the extraction fix. Retain the existing corpus result honestly: 3% remaining number-read sites, not the original 2% target; #1189 owns the remaining metric/styles.

### E. Interrupted recording — controlled failure, separate from the walkthrough

Use an isolated installation on a spare device, or an explicitly approved disposable capture on the owner's phone after preserving the baseline. This is not an unattended “cleanup” step. Do not kill a process with unrelated work underway, copy an inconsistent live SQLite database, or alter the owner's draft files.

1. Record 10–30 seconds with a known source, anchor and distinctive test phrase. End the process **before Save**, preserving the same container. Record whether this was app-switcher force-quit or process termination; they are different mechanisms, neither proves jetsam survival. Run without a debugger for the real lifecycle observation.
2. Preserve test draft metadata and associated file before recovery where possible, then relaunch. Check exactly one recovered Margin at the original source/anchor **if the audio decodes**, or a truthful one-time unrecoverable notice with surviving audio retained. Neither a generated transcript nor a broken playable-looking Margin is acceptable. No automatic playback.
3. Relaunch a second time: no duplicate and no repeated notice. Also check normal Save survives restart and deliberate Cancel does not recover. Inspect only the disposable draft/file identities; owner recordings remain untouched.
4. Verify real AVFoundation decodability/duration and have the owner listen to the recovered test audio. A notice can pass #951's current truthful-recovery behavior, but it must be reported as **audio not recovered**. It does not prove that the original broader audio-durability aim is solved.

## F. Controlled checks that do not consume the owner phone

These are necessary proof, even where a label says “human validation.” Run host cases in real temporary stores; app-hosted/simulator work goes through the Test Desk/lane after #1101's resource needs. Do not trigger memory pressure, manipulate credentials or corrupt the owner's Library to manufacture these conditions.

| Issue | Controlled sequence and decisive observation | Existing evidence path / limit |
| --- | --- | --- |
| #1031 | Feed speech at −30 dBFS every 0.1 s for 3 s immediately after start tone, then −55 dBFS for 4 s; it must save. Controls: one quiet calibration sample first, loud −20 speech, and silence-only flag. Run the regression against pre-fix code to see its intended assertion fail. | `HandsFreeMarginCoordinatorTests`. Current `App/` has no calls to this coordinator. Add-a-Margin word capture cannot validate its threshold algorithm or invent a tone path. |
| #1051 | Both private-feed URL shapes × query, fragment, slash, http, whitespace/case; inspect actual outgoing canonical HTTPS URL and deduplication. Public/lookalike/no-token URLs remain public. Use synthetic tokens and intercepted requests first. | `SubstackPublicationResolverTests`; a live subscribed feed is optional end-to-end evidence only when the owner supplies access. Never send a real token over HTTP or copy it into reports. |
| #1107 | Queue a long article; deliver one controlled memory warning during preparation. Observe warning/backoff, then a new completed chunk without any tap within roughly 90 s. Repeat with cancellation (no restart) and continually renewed backoff (bounded stop). | `PreparationHeatWaitTests`, especially `testTheLoopRunsThePassAgainOnceAMemoryBackoffEnds`. Simulator warning through the lane; the issue's Simulator menu is not an iPhone button. Normal preparation without a warning does not test this. |
| #1466 | Quarantine a Margin/turn/session and real audio in a temporary SQLite fixture; permanently delete its parent, reopen, make old payload decodable, reopen again. Deleted graph/audio stays gone; unrelated quarantined/live data and shared files survive. | `SQLiteQuarantinePermanentDeleteTests` plus app permanent-delete test. Deleting an ordinary item on the phone does not exercise quarantine. No owner data deletion is required. |
| #1469 | Start session A and hold summary A. Start B, once with its own held summary and once without. Fail A alone. Inspect persisted A/B jobs/turns, return to A, exercise offered recovery, and change A's target to test truthful scope. | `SummaryFailureOwnershipTests` covers storage cases; app UI/retry evidence needs independently addressable controlled provider responses. Airplane mode fails unrelated requests and is not a valid substitute. Use a stub provider in the isolated app test, no paid API or owner account changes. |
| #1545 | Run existing phone-plan tests and generate plans into a disposable output for `437fbc9` and the selected candidate. Old reverted #447/#450/#451 features must be excluded at the former; after #1551 they may be included only if actually present in the candidate. Check #1475 restoration is not re-asked. | `scripts/tests/test_phone_build.py`, `reverted_prs` / `waiting_fixes` in `scripts/phone-build`. Do not use `--plan-only` on the shared `latest`: it rewrites the owner's current plan. No phone minutes needed. |

The low-memory test distinguishes a synthesized warning from actual pressure: [Apple's memory guidance](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use) explains that Simulator does not reproduce a device's memory-pressure environment. Neither test substitutes for the other.

## Verdicts and stopping rules

- **PASS:** all specified preconditions and observations for that case/repetition are present. Record the evidence and exact build. This still does not set `human_validated`.
- **FAIL:** the stated behavior fails with the necessary precondition established. Preserve the first failure, use the normal bug workflow, and stop dependent steps. An additional repetition is for a distinct condition, not to erase a failure.
- **BLOCKED:** required state cannot be reached (for example no playable Margin, no prepared edition, missing exact PDF or unreleased phone). Name the missing prerequisite once; retry only after it changes.
- **INCONCLUSIVE:** lost event window, stale/mismatched build, absent required counters, no listening witness, or test setup failure. No missing value becomes zero and no empty list becomes success.

Stop for unexpected Library changes, repeated process crashes, serious heat or lost device access. Preserve evidence before any reinstall/relaunch. Do not manufacture memory pressure or run stress loops on the owner's phone. A failure in #1101's path hands the phone back to that work; it does not start a competing investigation here.

Each issue result ends with: **build; precondition; actions; observed result; raw evidence; limits; owner acceptance pending/received**. Report regressions separately from collection failures. Keep raw logs, screenshots, audio, source fixtures and exports ignored under `artifacts/`; only scrubbed summaries go to issues.

## Cost and catch

This protocol adds no scheduled job or CI gate. Per requested session: approximately 15–25 owner minutes, a passive notes interval, and seconds of Mac work per bounded JSON copy/summary; optional profiling or fault-injection tests are separate, explicitly costed runs. Stop after one complete case set, expanding only for a failure or a missing condition.

It catches known false proofs: #1030's host rule passing while iOS delivered no headphone command; #1036 being attempted before a Margin voice played; #1545 asking for reverted UI; #1192 suppressing log noise without proving work stopped; and seeded/tone-based tests missing real phone boundaries. If a collected file cannot change a case verdict, omit it from the next run. Do not add this manual protocol to the recurring lane ledger or schedule without a separate need and cost review.
