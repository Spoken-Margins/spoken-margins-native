# Second edition: supervised native implementation

Status: approved and in progress, September 10, 2026. The owner authorized the broader redesign, named agents and file ownership after shipping the MVP to beta testing. AGENTS.md and the release lane are updated. Usage floor: 20% remaining; adapt the approach if consumption trends poorly. Approval of the proposal's appearance is not native flow validation.

## Outcome and decision model

A returning listener can choose an item immediately, pause or capture a thought without searching through the player, and find the saved Margin without losing their current listening session. The remaining intake, following, sharing and storage screens should follow the same useful, quiet composition. Implement this in the existing SwiftUI app; the HTML is a reference, not an embedded replacement app.

The owner's correction is the primary design constraint: beautiful introductory copy displaced useful content and forced unnecessary scrolling. A screen that resembles the reference but repeats that failure is rejected.

| Layer | Facts and constraints | Consequence |
| --- | --- | --- |
| People and tasks | Returning listener, person capturing a fleeting thought, person retrieving notes, sender and recipient | Organize work around complete tasks, including recovery; do not assign isolated screenshots as features |
| Resources | Phone viewport, readable text, attention, saved source position, original recordings; 84% weekly Codex allowance remaining at initial check | Protect controls and context; measure model consumption and rework in a pilot |
| Existing mechanisms | SwiftUI views, app orchestration, SessionKit, persistent store, audio adapters, package verification | Reuse canonical behavior; do not reproduce browser demo state in production |
| Execution topology | One shared checkout; player view 5,263 lines and app model 15,144 lines at the inspected baseline | One owner for shared integration; at most one delegated code writer; parallel review only against a frozen diff |
| Authority | The owner approved the broader release amendment, named agents, file ownership and 20% usage floor; the lane and `AGENTS.md` record that approval | Implement the authorized scope on the current lane; reserve distribution and human validation for the owner |
| Evidence | Browser QA covers layout and demo interactions; tests cover selected native behavior; only the owner accepts product flows | Keep `implemented`, `verified`, and `human_validated` separate |

Success means task completion, truthful state, preservation of content and playback, readable accessible controls, and consistent appearance. More visible rows alone cannot establish success. The compact current-item row must still make resuming recognizable.

## Evidence and design authority

The inspected repository is `codex/provisional-next` at `ec2155707b3f416932123c4bf56d939fb209d4ba`. Its native candidate still identifies as 0.1 (26); this is not the exact distributed Build 26 source. The second-edition design remains an uncommitted, design-only change. Preserve it and all unrelated changes.

The reference is `Design/UXProposal20260909/public/try.html`, with `prototype.js`, `book.css`, and `research/second-edition.md` in that proposal directory. The private published design is [the second edition](https://spoken-margins-experience-book.uncomposed.chatgpt.site/try.html), Site version `appgver_4c2790c24b6481918118f21e1faff1f1`. The local reference hashes are recorded in [the reference snapshot](second-edition-reference-snapshot.md). Recheck them at kickoff. A changed reference needs a recorded design decision, not silent drift.

Order of authority: the owner's explicit decisions; the release lane and applicable product contracts; this approved plan and its behavior requirements; the reference's composition and visual language. Browser fixtures are illustrative. They do not authorize fake readiness, simulated recording, invented source identity, or disclosure of full native-audio transcripts. When the reference conflicts with a real capability, preserve truthful behavior and record the visual adjustment.

## What the code already supports, and what needs work

| Area | Inspected evidence | Native work |
| --- | --- | --- |
| Library | `ExperienceLibraryScreen.swift`; `Gate1AppModel.visibleLibraryItems` already searches title/source/author and applies filters and sorting | Replace hero-heavy hierarchy, expose existing queries compactly, preserve preparation, completion, replay and deletion rules |
| Player | `PlaybackScreen` in `Gate1RootView.swift` puts transport and capture inside one scrolling body | Separate scrollable identity/content from stable primary controls; retain real scrub lifecycle, semantic text navigation, Mix, Skim and playback ownership |
| Capture | `ExperienceRecordingScreen.swift`; `SessionEngine.beginInterjection/finishInterjection` are recording-oriented | Compact real recording and recovery; implement written capture as a distinct transaction, not a fake audio recording |
| Margins | `ExperienceMarginsScreen.swift` shows summaries before notes; `MarginRow.id` is session-qualified | Put notes first; add local note search and useful filters without collapsing session identity |
| Detail and return | `ExperienceMarginDetailView.swift`; `openMarginInTimeline` deliberately blocks replacing a different active session | Keep browsing passive; add an explicit, correctly addressed Play this moment action and safe context retrieval |
| Curation | `Interjection.isStarredForSharing` and sender-review curation exist | Reuse persistent curation; inspect cross-session mutation ownership before wiring global rows |
| Intake and Following | Existing typed intake routes, candidate resolution, source following, queue and retries | Compact route choices; display Following while retaining stable internal source identifiers; preserve import-only behavior |
| Sharing and offline | Existing Build23 sender/recipient flows, integrity checks and storage ledger | Recompose existing behavior; retain rights review, fallback choices, unresolved placement and protected originals |

Files in this table are under `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` unless prefixed otherwise. `SessionEngine` and `Interjection` are under `Packages/SessionKit/Sources/SessionKit/`. Nullable `audioPath` is evidence of representational flexibility, not proof that written capture works end to end.

## Non-negotiable design and behavior requirements

| Requirement | Review and falsification |
| --- | --- |
| Useful first view | With the agreed ordinary fixture, Library shows item rows, Margins shows note excerpts, and Add shows real intake choices before a preliminary scroll. No marketing paragraph or redundant title block appears above them. Compare the current native screen and the proposal with identical data |
| Reachable primary controls | Pause/Play and Add a Margin remain reachable without scrolling past content. Recording Save and Cancel remain available with long titles. At accessibility sizes, move secondary actions into a labeled menu before sacrificing text size or primary controls |
| Readability and beauty | Use semantic native text styles, warm surfaces, green emphasis, restrained separators and readable note typography. Do not use fixed browser font sizes, shrink-to-fit text, or color alone for state. Inspect dark appearance, increased contrast and reduced motion |
| Stable identity | Open Margin B while item A is playing: A, its rate and its position remain unchanged. Only Play this moment may switch to B. Use session-qualified IDs and the correct text/media/generated-content anchor |
| Truthful capture | A voice note requires a real recording. A written note retains exact text, has no recording-play control or transcription retry, and needs no microphone permission. Saving failure keeps the draft and the locked anchor available for retry |
| Honest capabilities | Readiness, offline availability, microphone state, matching and source ownership come from real native state. No hard-coded demo timer, waveform implying captured audio, successful-import toast, or sample source stands in for an operation |
| Preserve established semantics | Keep media seek versus text navigation distinctions, original source position across Skim, recording exclusivity and audio restoration, import without autoplay, original recordings, and sharing consent boundaries |
| Useful recovery | Search with no results offers clearing the query; permission denial offers settings and written capture once implemented; unresolved import stays unresolved; preparation failure exposes supported recovery |

These are review requirements, not new runtime command IDs, snapshot fields or fixture families. Any runtime vocabulary changes must update their schema, validator, implementation and tests together.

## Delivery sequence

### M0 — Baseline and execution contract

Approve the amendment and ownership packet in [the proposed decision](second-edition-release-decision.md). The steward then records the owner's decision in `docs/release-lanes.md` before implementation. Stay on `codex/provisional-next`; do not revive a historical branch. Freeze design hashes and the current native input hash. Preserve the existing design diff separately from native changes.

The baseline fast plan passed on September 10: runner, contracts, surfaces, inventory, browser and package suites. Evidence: `artifacts/test-runs/20260910-130912-829247-fast/manifest.json`, input hash `ce4a191b3637e6dec67709135dd6376eb282842d924743a2acc08d900adee334`. This is not an app, accessibility or release gate. Capture the current native Library, player, recording and Margins screens before changing their composition; prior audit images may illustrate the problem but cannot substitute for exact-build comparisons.

### M1 — Prove the core listening loop

Implement Library, player, recording and private Margin list/detail composition using existing capabilities. The steward owns shared tokens, navigation, player integration and app-model changes. Terra implements the bounded surface packet. Reuse existing search/sort semantics at this stage. Keep existing secondary actions reachable and existing recording lock behavior intact.

Acceptance: select a specific prepared item; start and pause it; capture a real voice Margin; save and resume; open the saved note; return to listening at the correct source position. A different note can be read without silently switching playback. Repeat with a long title, populated Library and larger native text. Run fast/app plus the relevant scoped UI routes. Inspect actual screenshots; compilation is insufficient. M1 is the calibration pilot, not a claim that the entire design is finished.

### M2 — Make retrieval work across sessions

Add local private-Margin text/title search, Starred and attention recovery filtering, complete detail text, bounded source context disclosure, and explicit Play this moment. Keep imported commentary visibly separate and include it in Shared results only through its own identity and provenance model. A global search must not expose a full native-audio transcript. Search is deterministic and local; semantic search and embeddings are outside this release.

Acceptance: a 50-note synthetic collection contains one distinctive phrase; search finds that note and an absent phrase returns no matches. Two sessions with colliding note IDs remain distinct. Read and star a note from a different session while A plays; reconstruct the store and confirm the star belongs only to that note. Explicitly play its source moment and confirm the right source/anchor. Wrong or unavailable anchors must produce recovery instead of confident misplacement.

### M3 — Implement written capture and denial recovery

Before coding, the steward freezes a small written-capture behavior contract and the exact additional file allowlist. Opening the composer locks the currently heard target and position, pauses source playback, and stores its prior play/pause state. Saving commits nonempty text (trimming only to check emptiness) to that locked target exactly once and restores the prior transport state. Cancel confirms discarding nonempty work and restores the prior state. A save failure preserves draft and anchor. Denied microphone access must not be required for opening this route.

Preserve interior whitespace and the user's words; do not automatically clean or summarize them. No audio file, transcription request or acoustic-evidence capture is created for written capture. App interruption must not publish a partial Margin or allow late completion to attach it to another item. Reuse the canonical store, export and anchor machinery; do not create a parallel notes database. If a new capture-kind field is necessary to distinguish written notes from missing recordings, add backward-compatible decoding and old-store evidence in the same intentional change. Text-only sharing must retain the existing consent and package rules.

Acceptance: written note survives reconstruction with exact text and anchor; zero microphone/transcription invocations; cancel creates no record; failure-and-retry creates one record; pre-paused playback stays paused; generated-response notes retain their generated target label. Add meaningful engine/app tests and update active inventory for any new tests or runtime contracts.

### M4 — Carry the same intent through the remaining screens

Recompose Add, ready/item detail, Following, Timeline, sharing/received review, offline preparation/storage, settings, completion, Skim and shared playback. Use existing platform pickers, disclosures and capability gates. Prefer collapsing supporting information to removing a necessary warning or recovery action. The visible Sources root may become Following while its persisted/internal identifiers remain stable. Keep current gestures; the second edition supplies explicit navigation so nobody must discover a gesture to proceed.

Acceptance includes empty Library → import → item ready without autoplay; ambiguous import recovery; followed-source additions without duplicates; selected-note sharing preview with private exclusions; recipient mismatch stays unresolved; offline failures remain recoverable; stored originals remain protected. Inspect all 20 reference states using the coverage table below. The browser's abbreviated sharing screen must not erase native review, cleanup, rights or matching controls.

### M5 — Integrate, verify, and hand off

Stop writes while running verification. Run the required plans on the exact candidate and inspect failures rather than weakening assertions. Recheck visual fidelity and task usefulness after integration, including long titles and native accessibility sizes. Record known issues and evidence limitations. Prepare a reproducible candidate with build number, SHA plus any uncommitted input hash, devices/OS versions, sample items, reset instructions, diagnostics location, and the owner's pass/fail checklist under `artifacts/validation/gate-1/second-edition/`.

Do not silently consume the next upload number. The project currently targets iOS 18+ on iPhone/iPad. An installed iOS 26.5 phone and iPad simulator are available; an iOS 18.6 runtime is listed without an available device. Add a suitable test simulator if supported or report that minimum-OS runtime evidence as missing. Actual audibility, headset/Lock Screen restoration and one-handed comfort require the owner's physical-device use. No TestFlight upload or promotion to `main` is part of this proposed implementation authorization.

## Coverage and omission check

| Reference state | Milestone | Required evidence |
| --- | --- | --- |
| library, listen, record, saved | M1 | Real selected identity, capture anchor, resume and stable controls |
| margins, note | M1–M3 | Retrieval, passive browsing, persistent star, explicit playback, written-note truth |
| timeline | M2/M4 | Correct session and generated/source labels; accessible note focus |
| add, ready, item | M4 | Direct intake; real readiness; existing sessions/chapters and no implicit autoplay |
| sources | M4 | Following identity, distinct new items, duplicate suppression and retry |
| share, received | M4 | Selection, consent, integrity, matching, private-data exclusions and no autoplay |
| offline, settings | M4 | Real availability/protection; immediate settings and recoverable actions |
| first, finished | M4 | Useful empty action; completion and deliberate replay/review |
| skim, shared-playing | M1/M4 | Correct audible target, source pause/return, existing cue and dismissal behavior |
| permission | M1/M3 | Native denied/restricted state; recover or write; no permission loop |

Every visible prototype control must be mapped to an existing native action, implemented here, or explicitly recorded as outside scope with owner acceptance. Decorative-only buttons and simulated success are not acceptable closure.

## Verification method

Use `docs/testing.md` and the existing runner rather than inventing a second harness. From the repository root:

    ./scripts/bootstrap-python-tools.sh
    .venv/bin/python scripts/verify-tests.py --plan fast
    .venv/bin/python scripts/verify-tests.py --plan app --device PHONE_UDID
    .venv/bin/python scripts/verify-tests.py --plan ui --device PHONE_UDID
    .venv/bin/python scripts/verify-tests.py --plan ui --device IPAD_UDID

Replace the destination placeholders with IDs from `xcrun simctl list devices available`; do not rely on its first phone because another project has a booted simulator. Available Spoken Margins phone: `856FA6EF-5E03-4120-939B-F0EF42A804E8`; iPad: `BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51`. The steward alone controls Xcode, the verification runner and simulator interaction. No source edits occur during a runner invocation.

Use focused existing selections for iteration; the full UI plan is an integration checkpoint on both form factors. Audio/inference changes additionally require `--plan adapters`; speech-input/playback changes require `--plan speech-canary`. Before release handoff run `--plan release`. Run generic simulator/device builds when app integration changes, as required by `AGENTS.md`. Do not build archived Watch features merely because the design changed. Do not count an interrupted run, missing test or unexpected skip as passed.

Compare the same source text, item/session identifiers, playback position and note corpus before/after. At default text, capture ordinary small-phone and iPad layouts; then the longest-title fixture, largest native accessibility type, keyboard, dark/increased contrast and reduced motion. Inspect actual screenshots and accessibility reachability. Do not make brittle pixel snapshots the sole proof. Negative cases must catch wrong-session notes, incorrect anchors, fake readiness and hidden primary controls.

The app tests already cover navigation, presentation, sharing seams, source import and persistence. Extend the cheapest real seam when behavior changes. Do not add tests solely to assert a constant padding value. Keep package disclosure and source identity tests even when a change appears visual.

## Coordination, alternatives and usage

Recommended topology: this task is the design/integration steward; one Terra agent writes one bounded surface packet; a second Terra agent reviews a frozen result without editing runtime code. Maximum three active agents including the steward. The exact names, allowlists, prohibitions and merge order are in [the work packet](second-edition-work-packets.md). These assignments were approved on September 10. The archived gate workflow is not automatically reactivated.

Compared alternatives: one agent end to end has least coordination overhead and remains the fallback if Terra produces substantial rework. Multiple feature writers could shorten independent coding time, but shared navigation/model/player files and a serial simulator/build lane constrain this repository. A large swarm would duplicate context and increase integration work. Broad architecture cleanup before the UX would spend budget before proving value. Prefer only the view extraction necessary for the current milestone.

OpenAI documents Terra as a model balancing intelligence and cost; that supports trying it for bounded implementation, not a promise about this account's quota multiplier. The proposed medium reasoning setting is a pilot starting point. Escalate a difficult packet after concrete failed attempts or a domain ambiguity; do not retry the same vague prompt repeatedly.

The initial weekly reading is 16% used / 84% remaining, shared across the account. Proposed operating guardrail: review usage after each milestone, and after the pilot or five percentage points of additional account consumption, whichever comes first. Reserve 20 percentage points for integration fixes and verification, and preserve 20 points for the owner's other work. With 84 initially available, that makes at most 44 points available to ordinary implementation before entering the integration reserve; it is a planning envelope, not a cost forecast or tool-enforced cap. Stop starting new milestones at 40% remaining; use the integration reserve only for finishing/repairing already started work; stop model work at the 20% floor with an exact handoff unless the owner changes the budget. Checkpoints can lag a running turn, and other tasks can consume the same account allowance.

At the post-research check on September 10, the account reports 19% used / 81% remaining. The observed three-point account change is not a task-specific cost measurement. At that reading, ordinary implementation has a 41-point envelope before the 40% checkpoint. Re-read usage at actual kickoff rather than treating either reading as a permanent budget.

Record milestone start/end usage, elapsed implementation and verification time, accepted outcomes, review defects and repair passes. Do not attribute all account consumption to this project. After M1, estimate later work from observed evidence with uncertainty; do not invent a week-completion promise. If two repair passes cannot satisfy a behavioral requirement, reduce parallelism and have the steward diagnose the mechanism. A budget checkpoint never authorizes silently dropping a state or calling unfinished work complete.

## Progress, decisions and current outcome

- [x] Inspect reference intent, native seams, release lane and coordination rules.
- [x] Read current official model guidance and planning documentation.
- [x] Verify the baseline fast plan and prepare explicit implementation/ownership packets.
- [x] Owner confirmed the release amendment and named agents; revised the usage floor to 20%.
- [x] M0 approval and reference hashes recorded; current-build Library/player/recording baseline captured (Margins baseline remains source/audit evidence).
- [x] M1 core loop pilot, evidence and measured budget calibration.
- [x] M2 retrieval and identity-safe return.
- [x] M3 written capture and permission recovery.
- [x] M4 remaining state coverage.
- [x] M5 integrated verification and owner handoff.

Baseline discoveries: Library search/sort already existed; written capture lacked a public transaction; global Margin navigation refused implicit session replacement. The implementation now supplies canonical written capture and an explicit source-moment transaction. Large shared files and serial test ownership limit useful parallelism. The original design critique remains a release acceptance criterion.

Baseline evidence gap resolved: the earlier audit's iPad launch was unproven. M5 subsequently executed all ten UI seams on iPad; a stale installation at simulator boot explains the supplied startup crash. The final matrix is being refreshed after the accessibility layout repair. Exact runs and limitations belong in the final handoff.

Decision log: September 10 — propose staged native reuse, one surface writer, independent evidence review, and steward-owned shared changes. Keep secondary capabilities and source rights boundaries. Carry the entire second-edition state inventory, while distinguishing new behavior from presentation. No native release or parallel-work authorization is inferred from the owner's visual endorsement.

Current outcome: M0–M5 are implemented and verified. The final candidate, evidence identities, limitations and pending owner checklist are in artifacts/validation/gate-1/second-edition/handoff.md. No redesigned flow is human_validated.

September 10 kickoff: account usage is 21% used / 79% remaining. With the owner’s revised 20% floor and the 20-point integration reserve, ordinary implementation has a 39-point envelope before the 40% checkpoint. Supervision will use packet completion events and concise milestone reports rather than repeated monitoring.

## Research used

Checked September 10, 2026. These are inputs to the method; the repository-specific topology and budget percentages are recommendations, not published OpenAI guarantees.

- [GPT-5.6 Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra): documented intelligence/cost positioning; local tool metadata also exposes `gpt-5.6-terra` for agents. No exact Codex weekly-allowance savings were established.
- [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans): keep a durable plan with observable outcomes, progress, discoveries and decisions. This plan adapts the method; it does not import the example's old model recommendation or wholesale repository rules.
- [Modernizing your Codebase with Codex](https://developers.openai.com/cookbook/examples/codex/code_modernization): start with a bounded pilot and inventory real behavior; compare before/after using explicit parity evidence.
- [Long-running work](https://learn.chatgpt.com/docs/long-running-work): define outcome, constraints and verification; keep related work together and avoid overlapping writers. A persistent goal may be useful after scope authorization, but this task has not enabled one or created a background automation.

### Execution log · September 10

M1A: Terra Library and steward fixed player dock compiled; smoke passed at `artifacts/test-runs/20260910-141310-192478-smoke/manifest.json`. Actual new Library screenshot inspected against the baseline: content begins directly below search/filter controls. Independent review found a nested-sheet navigation risk; replaced the sheet with a real Margins-root action and added the capture-to-Timeline UI route. M1B recording and note review are implemented; fast/app verification is running with code frozen. No new native flow is human-validated. Usage at M1A checkpoint: 24% used / 76% remaining.

M1 native fast and app plans passed: `20260910-142136-272653-fast` and `20260910-142151-456049-app` (393 app tests). UI verification is running. Account checkpoint: 26% used / 74% remaining. RT-2/3 has an explicit bounded Terra runtime lease; no writes until verification releases the source freeze.

First M1 UI run (`20260910-142842-496133-ui`) completed with 2 passes and 7 failures. Accessibility hierarchy proved the screen identifier propagated onto all dock buttons; this is an implementation failure, not test flakiness. The fix uses explicit accessibility containers. Existing Export routes now go through More. A focused three-route repair run is pending; the full phone/iPad integration gate remains required.

M1 repair evidence: fixed dock controls passed the focused test, but screenshot inspection falsified its claimed maximum Dynamic Type setting (the old literal was not a UIKit category). The test now uses the actual UIKit raw value and requires the accessibility layout. Two later failures are explained by natural sample completion: videos show Item at 94% and post-cancel Playback at 89%, then the old auto-close forces home. Bounded completion correction added to RT-2/3; M1 acceptance remains pending. CUA manual inspection of the frozen pilot confirmed ordinary item/Export opening.

31% used / 69% remaining at runtime integration checkpoint. The combined Terra runtime packet returned twice without tests/rollback, so it is split into smaller behavioral leases (RT-W then RT-P). The steward takes back app integration; no incomplete runtime capability is accepted. This addresses task breadth rather than increasing monitoring.


Integration checkpoint: 36% used / 64% remaining. RT-W and RT-P returned authored transaction and rollback tests; the first combined fast run failed a JSON-null fixture assertion, repaired explicitly as NSNull. Fast now passes at `20260910-151213-928894-fast`. UI-4A/4B have returned, completing task-first Add, Item, Following, sharing and offline composition. Steward integrated compact Timeline/settings, fixed shared/Skim return controls, full written composer and global retrieval, and authored permission-race and end-to-end written UI coverage. All implementation files are frozen for app execution; the independent runtime review has an exact per-file SHA-256 manifest under `artifacts/reviews/second-edition/runtime-review/`. No publication or release-build-number change.


Native compilation repairs: the first integrated app build exposed misuse of transport status for the existing `SessionPhase.finished` state and a private Skim cancellation method. Repaired with phase checks and a bounded app action. The next app build compiled production sources and failed only a test fixture's nonexistent `SharedItemType.article`; corrected to existing `.text`. Neither failed run counts as verification. An attempted manual launch of the partially built app was rejected because the interrupted build had not signed it; wait for a complete build before simulator QA.

Independent runtime review returned export capture-kind loss and older unscoped destructive endpoints. The global-detail UI already restricts Manage to the current session, so the review's direct foreign-delete route is not established as reachable; nevertheless all destructive endpoints and private curation now receive explicit session identity, with duplicate-ID regression coverage. RT-E is an explicit narrow export/engine repair lease. Small-phone minimum-OS test simulator created: iPhone SE (3rd generation), iOS 18.6, `09B39C91-F60E-497E-9F7C-AAD8740FBAC3`.


Integration review closed scoped deletion and written export provenance, then found Item/Library Replay still routed to completed-session inspection. `startItem` now starts a new session for a finished preferred continuation; an unfinished latest session keeps Continue even if an older session finished. Explicit history inspection keeps the existing paused review behavior. A focused model regression preserves the old completed session while checking the new identity and initial position.

App execution `20260910-152036-357654-app` compiled and ran but failed four cases. Two new tests compared a snapshot from before seeding/normal lifecycle synchronization (active note count 0→1 and chapter metadata refreshed); their baseline now follows that setup, keeping full snapshot equality for the actual passive actions. Two unrelated existing cases returned SQLite extended code 6922 (`SQLITE_IOERR_VNODE`); cause not yet established and they remain failures until a complete rerun passes. No production persistence assertion was removed.


App rerun `20260910-152412-916300-app` built successfully but stalled before test injection. A one-second process sample showed the normal app event loop and no XCTest image, with zero completed cases. The steward cancelled Xcode after 197.852 seconds, preserved its failed/missing-test manifest and sample/screenshot under `artifacts/reviews/second-edition/test-host-startup/`, and shut down only the selected phone simulator before a same-source rerun. No source change or passing claim was made for that attempt.


App gate passes: `artifacts/test-runs/20260910-153054-602107-app/manifest.json` verifies all 400 selected app cases. This includes exact-session destructive/curation behavior, 50-note local retrieval and Shared separation, written persistence/permission recovery, finished retention/replay, and existing native/sharing semantics. SQLite I/O failures did not recur in the restarted or latest run. Phone UI integration is now running on the same frozen candidate; layout acceptance remains pending.


Visual integration repair: phone UI run `20260910-153213-684805-ui` passed 7/10 routes. Screenshots exposed oversized/clipped Library menus at actual maximum Dynamic Type and repeated Item readiness/cover content displacing Shared provenance. UI-4C compacts Item and imported layers; accessibility Library menus and secondary player controls now use named icons. Written keyboard capture itself saved correctly; its later star assertion had an ambiguous toolbar container/button query, now scoped to buttons. Written media context now truthfully remains unavailable without cached source text and offers no nonexistent retry job. Fast `20260910-154711-942982-fast` and app `20260910-155226-267202-app` pass the repaired input `bf1535fc80aee926140bb95024a46d76899e2995f222bab1ce804d8829895f9a` (401 app cases). A preceding app attempt stalled before XCTest injection and was cancelled after 243.519 seconds with zero tests; evidence is preserved, and the selected phone was restarted before the successful same-source run. The native UI rerun remains pending. Account checkpoint: 44% used / 56% remaining.


Phone UI `20260910-155349-714585-ui` passed 8/10 routes. Recipient provenance and largest-text fixed player passed. The Add Text route failed because its scroll helper dismissed the keyboard and returned the sheet to its medium detent; the source frame confirms the form/action were not stable. The repair pins Add above the keyboard, uses a full-height sheet for selected intake routes and accessibility sizes, and keeps failed import text with an inline error. The test now requires the button to be visible without a preparatory scroll. Written save/search/star/explicit play succeeded through the captured target screen; the next assertion used an identifier absent from the implementation (`playback.itemTitle.button`), repaired to the actual `playback.title` button. The final discard steps remain pending rerun. Also repaired the clipped writing icon at maximum text size and refreshed the sample tour's obsolete Interject/Done/Add-and-Listen instructions.


Verification isolation: the tour's three obsolete-copy assertions were corrected; a later app run found an intermittent `SQLITE_BUSY` in the pre-existing follow-discovery race test. Independent review traced the uncontrolled second SQLite connection and cleanup of live WAL files. A narrow DEBUG-only unit-test store accessor lets three affected tests share the app connection; guarded weak-reference teardown avoids unlinking live storage, and exceptional paths resume suspended follow continuations. The production bootstrap scheduler and SQLite contention policy are unchanged. Phone UI `20260910-161034-139191-ui` showed the correct written playback and then hit the same SwiftUI toolbar-container query issue on Cancel, now scoped to buttons. Its Timeline assertion stopped when a partly visible action became hittable; the test now scrolls the outer content until the complete action clears the mini-player or the bounded attempts fail. Add Text now uses a dedicated flexible editor to avoid the awkward nested scrolling form around its pinned action. Account checkpoint: 48% used / 52% remaining.


Storage repair is verified by app run `20260910-162304-380941-app`: all 401 cases passed. Fast `20260910-162251-571238-fast` also passed. Focused native run `20260910-162555-ui-focused-repair` completed the full written save/search/star/play/discard route; the Timeline clearance still failed after bounded outer scrolling, falsifying the hypothesis that the test merely stopped early. Timeline now owns its mini-player safe-area inset inside the scroll container and removes the hard-coded 132/212-point bottom reserve. The next native capture (`ui-inset-diagnosis`) visibly clears the full response action; its test failed because the ancestor identifier propagated into the newly nested mini-player, repaired with an explicit accessibility container. Mini-player symbols now fit their touch frames at maximum text size. A full phone UI pass is running on the new frozen candidate.

- M5 phone UI: all 10 UISeams tests passed on input `cf12b57c6fa013004d08c8aa9f8e339555652344b3b30282c4aa9a4ece6c88f1` (`20260910-163601-635849-ui`). Native screenshot review confirms compact Library, reachable fixed controls, real maximum accessibility text, dedicated keyboard editor, Item provenance and Timeline clearance. Usage checkpoint: 52% used / 48% remaining. Remaining work is device-matrix execution, release checks and handoff.
- The owner supplied an iPad crash report during M5 startup. Binary UUID and dependency comparison identified the stale pre-test installation; the current installed candidate matches built products and is executing the UI suite. Evidence: `artifacts/reviews/second-edition/ipad-launch-diagnosis/diagnosis.md`. No production API workaround was added.

- M5 iPad matrix caught two real tap-target failures: both voice and written Margin rows left their transparent middle noninteractive at regular width. Independent review and a native video frame support the diagnosis. Added an explicit rectangular hit shape inside private/Shared row buttons; kept detail-opening assertions and full route checks. Consolidated singular count and redundant Library byline copy fixes. Fast checks passed (`20260910-165536-435496-fast`); frozen candidate is now `0bd9a227e114cab03b57654c4301d077d93803481d84d9e64258ece92f2eae75`.

- M5 budget checkpoint: 62% used / 38% remaining. Ordinary implementation is complete; only integration verification, concrete defect repairs and handoff use the remaining reserve. Small-phone screenshots exposed fragmented Timeline provenance and a persistent player occupying over one quarter of the viewport despite passing geometry checks. The player now uses two compact rows at accessibility sizes; Timeline metadata stacks and omits the decorative rail. Full source identity and note content remain available to accessibility and detail navigation. Fast `20260910-173919-849527-fast` passed; focused native checks are running before the refreshed final matrix.

- M5 final release attempt `20260910-180817-477428-release` executed 436 cases: 434 passed, two failed. Native captures established an offscreen sender preview tap and a gesture originating inside fixed controls. Strict visible-target test correction restored the sender flow. A further real pull defect required runtime measurement: ScrollGeometry already excludes the top/dock insets from its container. Corrected that conversion and the short-content resting offset; the complete gesture/reflection/keyboard route passed in `20260910-184456-release-focus`. Temporary logging is removed. A new short-content threshold regression joins the app suite. Refreshed device UI, release and generic builds now run on input `b001d9d4d1090b645e8dfbe8c005cc64eb8a496af6eebc5102a53ec6f90a7aa4`. Usage checkpoint: 69% used / 31% remaining.


- Final integration repair: iPad UI passed all ten routes on the previous input; the expanded five-route iOS 18 matrix exposed a back-button center tap blocked by the 32-point edge-swipe overlay. A right-side diagnostic tap passed, and reserving the navigation-bar region then restored the ordinary center tap (`20260910-191946-small-return-repair`). The diagnostic offset was removed. Final source input is `7632bd366c275aa8596a1a1d0210eb4ee9bf7fd76de210b0a0aba46d81e8f2bb`. Fast checks passed at `20260910-192140-400629-fast`; the serial device matrix, full release and generic builds are running. Usage checkpoint: 73% used / 27% remaining. No new implementation packet is open.


- Full integration gate passed on `7632bd…`: fast checks, 10 iPad UI routes, five iOS 18 small-phone routes, all 437 release cases, and generic simulator/device builds. Direct OS appearance inspection then found a white mini-player glyph on its light-green dark-mode button (1.75:1). Binding both its glyph and loading indicator to the existing audited `onEvergreen` foreground yields 10.33:1 and preserves white in light mode. A reconstructed input digest proves these are the only two implementation changes. Final candidate `0c18bd52030a46641fd5c02ba28592506b5d8eeedbf83ffa9c71b70e1ae560f5` is undergoing the complete phone release gate and both builds. Prior light-mode iPad/SE results retain their actual input identity; no new execution is inferred.

Final closeout: input `de27462fa86d9c071062ed9bf7a539e8b0fd0551c4efcbffaab79d3ed42e060b` passed all 437 release cases and both generic builds. Four dark-only color bindings were repaired after direct OS inspection; prior iPad/SE evidence retains its actual source identity. Weekly account check reached 19% remaining; stopped development and closed only in-flight local verification and handoff.
