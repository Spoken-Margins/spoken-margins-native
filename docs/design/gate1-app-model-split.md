# Taking Gate1AppModel apart

*Spoken Margins · architecture plan · 7 October 2026 · written against `next` at `be9faf86`; #935 has merged since and left the model at the same length*

This is a plan for a refactor. Nothing here changes what a listener sees. Claims about the code cite names on `next` at `be9faf86`. Line numbers drift, so check the code before you rely on one. Issue numbers are in the table at the end.

---

## In one minute

1. **The model is one 16,386-line file that almost every change touches.** 26 of the last 60 merges to `next` (4 to 7 October) edited it. That is why branches collide and why the hot-file ratchet keeps failing pull requests.
2. **A plain split into eight extension files was tried on 2 October and left as a branch.** It moved lines, not ideas. It had to remove `private` from 338 declarations, every method still read the same state, and it conflicted with every open branch. Extension files are still the right tool for what is left at the end. They are not the right first move.
3. **The plan is four kinds of slice, in this order.** There are 68 of them, one issue each.
   - **D, delete.** Six slices. Remove code that nothing calls or that never compiles. About 900 lines.
   - **P, pure.** 31 slices. Move logic that needs little or no model state into SessionKit, where it gets tests that run on Linux. About 2,700 lines leave the model.
   - **X, extension files.** 22 slices. Move what is left into extension files, one per concern. After the Build 30 tag, except X0, which only moves value types that sit in front of the class.
   - **T, types.** Nine slices. Give the biggest stateful loops their own types. After the extension file for that concern exists.
4. **The class keeps its stored properties, `init`, `deinit` and `didSet`s.** SwiftUI watches them, so they cannot move. The D, P and X slices cover about 11,200 of the 16,386 lines. **They take the file to about 5,000 lines, not 3,000.** About 1,300 of those are the stored properties and `init`. The other 3,500 are members no slice claims yet. Section 7 lists them, and a second wave takes them once the first has landed.
5. **The first slice is done.** The Listening Map JSON parser moved into SessionKit (#947). The model is 351 lines shorter, 18 new tests run on Linux, and the whole Linux suite passes (993 tests).
6. **Four calls are Cole's.** They are at the end of this page.

---

## 1. What is in the file today

The class runs from line 523 to line 16186. It has 677 methods (13,531 lines), 292 stored properties (157 of them `@Published`) and 97 computed ones. The declarations take about 1,066 lines. The value types before the class take about 500 lines more.

The mapping pass read all of it. These are the concerns, with rough sizes. The sizes overlap at the edges, so they do not add up to the file's length.

| Concern | Lines | Where it ends up |
|---|---|---|
| Stored properties, `init`, `deinit`, `didSet`s | about 1,300 | stays in the class |
| Library audio preparation (Supertonic) | 975 | P9, P14, P29, X15, T1 |
| Importing sources (links, files, Quick Add, browser text) | 1,060 | P4, P12, X4, X5, T8, D2 |
| Receiving shared Margins (packet import, placement, playback) | 1,230 | P18, P23 to P25, X7, X10, X16, T4, T5, T9 |
| Sending Margins (share sheet, packet export) | 850 | P21, P22, X9, T6 |
| Session export and batch export | 240 | X6 |
| Spoken and written Margins (capture, curation, Margins tab) | 780 | P13, X8, T7 |
| Playback transport, rate, skip, sleep timer, turns | 600 | P6 to P8, P31, X21 |
| Skim, episode maps, summary bridge, Listening Map generation | 960 | P1, P11, P19, P20, X18, T2, T3 |
| Library list, trash, completion, navigation, chapter jumps | 700 | P10, X2, X3 |
| Following | 410 | P17, X11 |
| Settings, voices, speech preview, engine install, audio clients | 1,300 | P27, X12, X13 |
| AI summary, discussion, provider (off in shipped builds) | 760 | D1, P2, P15, X14 |
| Transcripts, source-window context, anchor evidence | 890 | P3, P16, P28, X17 |
| Item detail, feedback, bookmarks, bootstrap, onboarding, seeds | 725 | X1, X19, X20, P30 |
| Watch bridge (never compiled) | 290 | D4 |
| Dead code and copy-paste | 650 | D1 to D3, D5, D6, P9 |
| Value types before the class | 500 | X0 |
| Members no slice claims yet | about 2,700 | second wave (section 7) |

Three facts shape the plan.

1. **Only 96 methods (1,054 lines) touch no model state at all.** Another 69 touch no stored property but call other model methods. That is the pure layer. It is small, but it is the part that can get Linux tests.
2. **SessionKit already holds the rules for most concerns.** The model often holds the glue, and sometimes a second copy. For example `audioPreparationJobPrecedes` forwards to `LibraryAudioPreparationQueue.precedes`, and the quarter-step rate clamp is written five times in the model while `SpeechRateRule` has no step. The slices extend those types. They do not make new ones beside them.
3. **About 650 lines are dead or duplicated.** One group never compiles (`#if SPOKEN_MARGINS_WATCH`, a flag nobody defines). The remote AI provider is off in shipped builds (`SMRemoteProviderExperienceEnabled: false`, `project.yml:119`) but tests turn it on, so it moves and is not deleted.

---

## 2. Why not just eight extension files

The 2 October attempt (`ws/319-codex-split-gate1appmodel-into-files-by-concer`, one commit, no pull request) cut the file into `+Playback`, `+ImportAndShare`, `+Margins`, `+Library`, `+Settings`, `+Following`, `+Onboarding` and `+Diagnostics`. The main file kept 657 lines. The fast plan failed, and the cause was not recorded.

What it shows:

1. **It had to widen 338 declarations.** 163 `private var`, 113 `private func`, 74 `@Published private(set)` setters and more became internal. A moves-only diff that changes access in 338 places is hard to review and weakens the type.
2. **Nothing got simpler.** Every moved method still reads and writes the same 420 properties. The file is smaller and the coupling is the same.
3. **It conflicts with every open branch.** The branch is now 626 commits behind `next`. 189 of those touched the model.
4. **It breaks a test that reads the file as text.** `ListeningSignalMergeIntegrationTests` reads `Gate1AppModel.swift` and checks function bodies. A split on `next` has to change that test too.

Extension files are still how the stateful remainder should leave the file, because they cut the merge collisions. The collisions are textual: two pull requests edit different features in one file. Ten files mean ten places. But they come after the pure logic and the dead code have gone, so there is less to widen, and they come in a quiet window.

---

## 3. The four kinds of slice

Every slice is one issue and one pull request. Every slice changes nothing the listener can see.

### D: delete code nothing calls

- Verify with `rg` over `App/` and `Packages/`, tests included, before each delete.
- The compiler is the second check. The lane builds for simulator and device.
- Two deletes remove something a person could in theory reach, so they are Cole's call: the Watch bridge (D4) and the live-speech gate (D5).

### P: move pure logic into SessionKit

- The new type goes in the SessionKit module the rule belongs to. SessionKit, Persistence, AI, EPUB and Feeds run on Linux. Audio, Sharing and Supertonic do not, so those slices say they run on the Mac host.
- The model deletes the block and calls the new type. Where a test or a view calls the old member by name, a one-line forwarder stays.
- Every slice has tests that fail when the rule they name is broken. The first slice was checked by changing the code twice and watching a test fail each time.
- These slices carry no `hot-file` label. They delete one block and swap call sites, which is what the label's "thin call sites" allows. Slices in different regions can run at the same time. Each issue names its region, because two deletes that touch each other conflict in git even though both only delete.

### X: moves-only extension files

- One `Gate1AppModel+Concern.swift` per concern. Bodies do not change.
- Stored properties stay in the class body. Each issue lists the `private` members its file needs widened, and widens only those.
- They carry `hot-file` and the `deferred` label. They start after the Build 30 tag, one at a time. X1 (the feedback methods) goes first because the others call `reportFailure` and `reportWarning`.

### T: a focused type for one concern's state

- Only the loops that are big and self-contained: library audio preparation, Skim, episode maps, imported podcast placement, packet import, bulk share preparation, the voice players, Quick Access, and the shared-Margin listening state.
- Each one starts with a short design note. AGENTS.md says do not add another resume flag or another playback state machine, so T9 removes flags and starts from `docs/gate1-playback-transition-table.md`.
- No `ready` label. A T issue becomes ready when the X slice for its concern has landed.

---

## 4. The order, and what waits for what

Every pull request in this plan stays unarmed until the Build 30 tag (the freeze, #894). "Starts now" means a thread may open the pull request now. It does not mean the pull request merges now.

1. **Now, in parallel: the `ready` D and P slices, and X0.** They sit in different regions, so several can run together. P19 only adds tests and touches no model code. The pairs below must not run at the same time or must run in the stated order, because their edits touch each other in git.
2. **After the Build 30 tag, in a quiet window: X1 first, then the other X slices one at a time.** Each X slice names the slices it waits for.
3. **After each X slice: the T slice for the same concern.** Each T slice starts with a short design note.
4. **Anything that needs Cole waits on his answer** (D4, D5, P26) and does not block the rest.

Order rules, from the mapping pass. Each issue repeats the ones that concern it.

1. D3 (#948), then P4, then P12. X0 leaves their value types where they are.
2. D2 before X4 and X5. D3 before X4 and X5.
3. P23, then P24, then X10, then X12.
4. P27 before P29. P8 and P27 are neighbours and do not share a hot-file window.
5. P9a, then P9b, then P29b. X0 before P29.
6. P18 before X7. X7 and X8 never run together. X7 before T9.
7. P21 before X9. P22 is independent of P21.
8. P17 before D6 and X11. P25 before X16. X11 and X16 never run together.
9. P16 and P28 before X17.
10. D1 and P2 never run together. Both before X14.
11. P11 and P19 before X18, and X18 before T2 and T3.
12. X1 before every X slice except X0.
13. P30 before X4 PR 2, X8 and X20, because it edits `startGuidedOnboarding` and `recordSavedInterjectionForOnboarding`, which those slices move. X0 and P30 can start together: X0 leaves the two onboarding enums for P30.
14. X20 PR 1 creates `Gate1AppModel+LibrarySeeding.swift`, and X4 PR 2 appends to it, so X4 PR 2 waits for it. X20 never runs with X4, X8 or X12.
15. P31 edits no line of the model, so it can run at any time. X21 waits for X1, P7 and P31, and never runs with X7, X8 or X12.

Open pull requests touch some of these regions. A slice in the same region waits until that pull request has merged, because Build 30 does not wait for Build 31. State on 7 October, checked twice that evening; check again before you start.

| Open PR | What it edits in the model | Slices to hold |
|---|---|---|
| #939 "Recording" only while capturing (#937) | the recording members; it also deletes `skipUnitForCurrentTarget`, `mediaSkipUnit` and `validatedMediaSkipSeconds` and widens `recordSavedInterjectionForOnboarding` | X8, T7, P7, X21, P30 |
| #906 Add Margin while a Margin plays (#866) | `beginInterjection`, `dispatchGate2CompactCommand`, `seekMedia`, `seekText`, and it moves `KeychainStore` out | X7, X8, X21, T7, D1 (the `KeychainStore` part) |
| #817 Save a Margin a call cut short (#771) | widens `reportWarning`, `run`, `scheduleTranscription` and four more, and `recordSavedInterjectionForOnboarding` | X1, X8, X13, X17, T7, P30 |
| #931 Export folder settings (#930) | batch export folder members, `resolvedBatchExportFolderURL` | X2, X6, X19 |
| #723 Share Margins from the Margins tab | `openMarginItemExport` | X9 |
| #901 One copy of a Margin on re-share (#858) | one line in the placement code | X16, P25 |
| #832 Text items show time left (#305) | `LibraryItemRow` and the row builder | X0, P29 |
| #713 Feed plain text (#711) | `importBrowserTextInBackground`, `sanitizedBrowserTextHandoff`, the followed-article import | X5, X11, X17 |
| #607 Skim destination on the Lock Screen | `updateSkimAvailability`, `updateGate2CompactState` | X18, T2, X12 |
| #344 Re-imported PDF with prepared audio | import and audio-preparation members | X5, X15, T1 |

#935 (placement passes) and #896 (source-window jobs) have merged. #938 (Timeline Back), #925 (Substack voiceover) and #570 (Following order) do not edit the model file. #903 (diagnostics ids) is an issue with no pull request yet; it holds P5.

**The lane is the bottleneck.** A diff that touches the model runs all 151 tests in `Gate1AppModelWorkflowTests`, about 15 minutes with the simulator boot, on one Mac. A slice that only adds a SessionKit type needs a Linux run and nothing else. Do not start more model-touching pull requests than the lane can run in a day.

**The ratchet.** `scripts/hot_file_ratchet.py` sets the ceiling at the smallest size the model has had on `next`. Each slice lowers it. A pull request that adds lines must still move the same number out, or carry `hot-file-ok`. The ratchet counts a branch's own net change, so landing a slice does not make room for someone else's Build 30 fix. Nothing in this plan changes the ratchet.

---

## 5. What every slice must do

1. **Change no behaviour.** Strings that reach a person or a model, ids, file paths, `UserDefaults` keys and diagnostics keys stay byte-identical. Each issue lists the ones in its code, and a test pins them.
2. **Move the body, not a rewrite.** No "while I am here" fixes. A bug found on the way gets its own issue (#949 and #950 came from this pass).
3. **Keep the names that tests call.** A forwarder stays until the test is retargeted in the same pull request.
4. **Widen as little as possible.** No `public` in the app target.
5. **Show the tests can fail.** For a move, break the rule once on purpose and show a test going red, as the first slice did.
6. **Ask for the right lane tier.** `scripts/test-scope.py` says T3 for any change to the model. SessionKit-only changes are T1. The lane runs T2 and T3.
7. **Get a Codex audit for packets, sharing, persistence, owner files or the audio session.** Each issue says yes or no.
8. **Stay unarmed until the Build 30 tag.** Open the pull request into `next`, request the lane, and do not add `automerge`.
   A slice that is several pull requests says so in its issue. Each pull request says `Part of #N`, and the last says `Closes #N`.
9. **Post the claim and stop notes** in the formats in the project instructions.

---

## 6. Hazards that cut across slices

The mapping pass found these in more than one place. An issue repeats the ones that apply to it.

1. **`snapshot.didSet` fires a long list of side effects**, including `updateSkimAvailability`, which writes back into `snapshot` under the `isUpdatingSkimAvailability` guard. Any code that assigns `snapshot` must keep that guard.
2. **`deinit` cancels only some Tasks.** Several Tasks have no stored handle, so their `Task.checkCancellation()` can never fire. Do not "fix" that in a move.
3. **Private members are called from far away.** For example `makeEngine` has 20 outside callers, `loadLibraryRows` 24, `installEngine` 24 and `rejectNavigationOrSessionMutationWhileRecording` 11.
4. **Tests reach into the model.** `MediaPlaybackInterruptionTests.swift:224` finds `interjectionAudioPlayer` by reflection, so moving that property breaks the test silently at run time. Several tests assert exact diagnostics strings, and `ListeningSignalMergeIntegrationTests` reads the source file as text.
5. **Some names are persisted.** The summary-bridge asset id, the voice key, the episode-map folder and `safePodcastEvidenceComponent` become SQLite rows and file names. A changed key orphans the owner's audio. P19 locks them first.
6. **`Application Support/SpokenMargins/IncomingPackages/<uuid>` is permanent** after a successful import. Nothing may add cleanup on success.
7. **`requireStore` can move the old SQLite file into `LegacyLibraryBackup/`.** Nobody touches it without a Codex audit.
8. **`resetAndSeed` has 172 test call sites in 20 files.** Move it byte for byte or leave it.
9. **Main-actor database work** is common (the rendered-frontier observer reads SQLite every 2 seconds). A move must not change which actor runs it.

---

## 7. Seen on the way, not part of any slice

**Bugs.** Two are filed: #949 (curly quotes around Listening Map keys do not repair) and #950 (heard-audio files for a streamed Margin stay in `Caches` when the context is already ready). The rest were read in the code and not run. They are in one issue, #972, with a repro to try for each. None is a reason to stop a slice. A moves-only slice never fixes one.

**What no slice covers yet.** About 2,700 lines of members are in no slice. The biggest groups are:

1. **Margin moments** (`startMarginMoment`, `playMarginMoment`, `playSharedMarginMoment`, about 110 lines).
2. **Playback ticks and session resume** (`tickPlaybackProgress`, `resumeSession`, `prioritizeOfflinePreparation`).
3. **Source transcript scheduling** (`scheduleSourceTranscriptImportIfAvailable`, `scheduleFullSourceTranscriptionForListeningMap`).
4. **Incoming URLs, read-later and browser text** (`handleIncomingURL`, `importReadLaterDocument`, `importBrowserTextItem`).
5. **Text-audio prewarm and offline services** (`scheduleTextAudioPrewarmIfNeeded`, `observeRenderedFrontier`, `configureOfflineServices`).
6. **Guided onboarding content** (`refreshGuidedOnboardingContent`) and compact-control setup (`configureGate2CompactControls`, `updateGate2CompactState`). The command entry points are in X21 and the command executor is in X12.
7. **Small groups** in the same shape: Gate 2 compact helpers, the per-item bits of session export, and a few one-caller wrappers.

The second wave starts when X1 and the first X slices have landed, because the extension files the first wave creates decide where these go. It gets filed then, from the mapping notes, not now.

## 8. How we will know it worked

1. **The model file's size.** 16,386 lines at the start. 16,035 with the first slice. About 5,000 when this plan is done, and the second wave takes it lower.
2. **Merges that touch the model.** 26 of the last 60 (43%) on 4 to 7 October. The critic's bar from #298 was under 10% of the next 20. Measure again after the extension files land.
3. **Linux tests.** 975 before the first slice, 993 after it. Each P slice adds tests that did not exist.
4. **Conflicts.** If merge syncs per pull request do not fall after the extension files land, the collisions are about meaning, not text, and only the playback coordinator (#185) helps. That is the "what would show this wrong" line from #319.

---

## 9. Decisions for you

1. **Watch bridge (D4).** 290 lines under `#if SPOKEN_MARGINS_WATCH` never compile, because no build defines the flag. **I recommend moving them to their own file under the same flag**, so nothing is lost and they leave the hot file. Deleting them is the other choice. Git keeps history either way.
2. **"Play Live Speech Instead" (D5).** The code behind that button cannot be reached in production, because nothing calls the function that shows it. **I recommend deleting it.** Say no if you plan to bring the button back.
3. **Legacy library archive (P26).** `archiveLegacyLibraryIfNeeded` moves the old database file aside. It has no tests and only acts on an old schema. **I recommend keeping it and moving it into the persistence module with tests**, because it touches your files. Deleting it is the other choice.
4. **Quiet window for the extension files (X).** They conflict with every open app branch. **I recommend starting X1 right after the Build 30 tag and running the X slices one at a time.** Do you want a different time?

Each answer goes on the slice's issue. A slice waits on its answer and nothing else does.

---

## Slices

Legend: **tag** means the Build 30 tag. D is delete, P is pure logic into SessionKit, X is a moves-only extension file, T is a new app-side type. "Waits for" lists the slices that must land first; the issues also say which slices must not run at the same time. "Codex audit" is whether the Astra audit is asked for on that slice's PR.

| Slice | Issue | What moves | Where it goes | Waits for | Codex audit |
|---|---|---|---|---|---|
| D1 | #989 | Delete dead provider code, dead types, and move KeychainStore | Deleted; `KeychainStore` to its own file | nothing | no |
| D2 | #967 | Delete the unused Piper voice import chain | Deleted | nothing | no |
| D3 | #948 | Delete members that nothing calls | Deleted (13 members) | nothing | no |
| D4 | #1017 | Decide what to do with the never-compiled Watch bridge code | Deleted or moved to its own file (Cole's call) | Cole's answer | no |
| D5 | #971 | Decide on the unreachable Play Live Speech Instead path | Deleted (Cole's call) | Cole's answer | no |
| D6 | #1003 | One accessor for each lazily created helper | One accessor per helper, in place | nothing | no |
| P1 | #947 | Listening Map JSON parser | `SessionKit/ManualListeningMapParser.swift` | done | no |
| P2 | #998 | Provider prompts and the assistant-chapter parse into SessionKit | SessionKit (Linux tests) | nothing | no |
| P3 | #1002 | Transcript file parsers (VTT, SRT, JSON) into SessionKit | SessionKit (Linux tests) | nothing | no |
| P4 | #955 | Quick Add selection and folder scan into SessionKit | SessionKit (Linux tests) | nothing | no |
| P5 | #968 | Diagnostics export builder and redaction into SessionKit | SessionKit (Linux tests) | nothing | no |
| P6 | #985 | Sleep timer rules move into SessionKit | SessionKit (Linux tests) | nothing | no |
| P7 | #974 | One playback-rate step rule and one skip-seconds rule | SessionKit (Linux tests) | nothing | no |
| P8 | #1001 | Playback chapter and header title logic into SessionKit | SessionKit (Linux tests) | nothing | no |
| P9 | #976 | Small pure helpers move into SessionKit | SessionKitFeeds | nothing | no |
| P10 | #988 | Library filter and sort move into SessionKit | SessionKit (Linux tests) | nothing | no |
| P11 | #992 | Skim scene walk and item scenes share one SessionKit rule | SessionKit (Linux tests) | nothing | yes |
| P12 | #959 | Welcome sample and file-import item builder into SessionKit | SessionKit (Linux tests) | nothing | yes |
| P13 | #962 | Margins list builder and query into SessionKit | SessionKit (Linux tests) | nothing | yes |
| P14 | #965 | Background preparation planner into SessionKit | SessionKit (Linux tests) | nothing | no |
| P15 | #973 | Discussion and summary prompt context into SessionKit | SessionKit (Linux tests) | nothing | no |
| P16 | #1006 | Source-context window and the local-summary reducer into SessionKit | SessionKit (Linux tests) | nothing | no |
| P17 | #994 | Source follow suggestion rules into SessionKit | SessionKit (Linux tests) | nothing | no |
| P18 | #978 | Shared-Margin prompt selection and eligibility into SessionKit | SessionKit (Linux tests) | nothing | yes |
| P19 | #996 | Lock the saved ids and paths with golden tests | SessionKit (Linux tests) | nothing | no |
| P20 | #999 | One list of transcription cache folders in SessionKitAudio | SessionKitAudio (Mac host tests) | nothing | no |
| P21 | #977 | Pure sender share helpers into SessionKitSharing | SessionKitSharing (Mac host tests) | nothing | yes |
| P22 | #1010 | Share-draft editing core into SessionKitSharing | SessionKitSharing (Mac host tests) | nothing | yes |
| P23 | #1005 | Shared podcast resolution rules into SessionKitSharing | SessionKitSharing (Mac host tests) | nothing | yes |
| P24 | #1009 | Imported-layer identity and repair logic into SessionKitSharing | SessionKitSharing (Mac host tests) | nothing | yes |
| P25 | #1000 | Podcast Margin fusion and status rules into SessionKitAudio | SessionKitAudio (Mac host tests) | nothing | yes |
| P26 | #1004 | Decide what to do with the legacy-library archive step | SessionKitPersistence, with tests (Cole's call) | Cole's answer | yes |
| P27 | #1013 | Small pure helpers and speech-status types into SessionKit | SessionKit (Linux tests) | nothing | no |
| P28 | #1014 | Podcast anchor evidence record updates into SessionKit | SessionKit (Linux tests) | nothing | yes |
| P29 | #980 | Library rows and queue rows built in SessionKit | SessionKit (Linux tests) | X0, P9 | P29a only |
| P30 | #1019 | Onboarding progress rules move into SessionKit | SessionKit (Linux tests) | nothing | no |
| P31 | #1021 | Move the autoplay queue and summary rule into SessionKit | SessionKit (Linux tests) | nothing | no |
| X0 | #964 | Move the value types before the class into their own files | 17 new app files, one per type | nothing | no |
| X1 | #982 | Move the feedback methods to an extension file | `Gate1AppModel+Feedback.swift` | tag | no |
| X2 | #1007 | Library action extension files (batch export, trash, completion) | `Gate1AppModel+BatchExportSelection.swift`, `Gate1AppModel+CompletionMarking.swift`, `Gate1AppModel+TrashUndo.swift` | tag, X1 | yes |
| X3 | #1011 | Navigation and chapter-jump extension files | `Gate1AppModel+Navigation.swift`, `Gate1AppModel+ChapterNavigation.swift` | tag, X1 | yes |
| X4 | #970 | File-import and Quick Access extension files, moves only | `Gate1AppModel+RemotePDF.swift`, `Gate1AppModel+PasteAndGo.swift`, `Gate1AppModel+FileImport.swift` and more | tag, D2, D3, P4, P12 (PR 2: X20 PR 1, P30) | yes |
| X5 | #979 | Source-link import extension files, moves only | `Gate1AppModel+RemotePDF.swift`, `Gate1AppModel+PasteAndGo.swift`, `Gate1AppModel+SourceLinkForm.swift` and more | tag, D2, D3 | yes |
| X6 | #983 | Export and batch export as an extension file, moves only | `Gate1AppModel+Export.swift` | tag, X1 | no |
| X7 | #987 | Margin voice playback (own and shared) as an extension, moves only | `Gate1AppModel+MarginVoicePlayback.swift` | tag, X1, P18 | yes |
| X8 | #990 | Margin capture, session close, curation, identity as extensions | `Gate1AppModel+MarginCapture.swift`, `Gate1AppModel+SessionClose.swift`, `Gate1AppModel+MarginCuration.swift` and more | tag, X1, P30 | yes |
| X9 | #958 | Sender sharing extension files (moves only) | `Gate1AppModel+ShareDrafts.swift`, `Gate1AppModel+ShareExport.swift` | tag, X1, P21, P22 | yes |
| X10 | #956 | Packet import and handoff inbox into an extension file | `Gate1AppModel+PackageImport.swift`, `Gate1AppModel+ImportInbox.swift` | tag, X1, P23, P24 | yes |
| X11 | #1008 | Followed-source actions into the Following extension (moves only) | `Gate1AppModel+FollowedSources.swift` | tag, X1, P17 | no |
| X12 | #961 | Settings, on-device speech status and engine install into extensions | `Gate1AppModel+SpeechSettings.swift`, `Gate1AppModel+OnDeviceSpeechStatus.swift`, `Gate1AppModel+EngineInstall.swift` | tag, X1 | yes |
| X13 | #984 | Audio client factory and interruption handlers extension | `Gate1AppModel+SpeechInterruption.swift`, `Gate1AppModel+AudioClients.swift` | tag, X1 | yes |
| X14 | #960 | Remote provider and AI jobs extension (moves only) | `Gate1AppModel+RemoteProvider.swift`, `Gate1AppModel+Summary.swift` | tag, X1, D1, P2 | yes (narrow) |
| X15 | #991 | Library audio preparation extension | `Gate1AppModel+LibraryAudioQueue.swift`, `Gate1AppModel+LibraryAudioPass.swift` | tag, X1, P9, P29 | yes |
| X16 | #1012 | Imported podcast placement and local-file readiness into an extension | `Gate1AppModel+ImportedPodcastPlacement.swift`, `Gate1AppModel+PodcastLocalAudio.swift` | tag, X1, P25 | yes |
| X17 | #966 | Anchor evidence, source-window context, Margin transcription (moves only) | `Gate1AppModel+ListeningSignals.swift`, `Gate1AppModel+SourceWindowContext.swift`, `Gate1AppModel+AnchorEvidence.swift` | tag, X1, P16, P28 | yes |
| X18 | #1016 | Skim bridge and episode-map extension files | `Gate1AppModel+SkimBridge.swift`, `Gate1AppModel+EpisodeMapPreparation.swift` | tag, P19, P11 | yes |
| X19 | #986 | Small moves out of the model in four parts | `Gate1AppModel+UITestingSeeds.swift`, `Gate1AppModel+PodcastDownloads.swift` | tag, X1, P11 | yes |
| X20 | #1020 | Library bootstrap and launch seeding as an extension file | `Gate1AppModel+LibrarySeeding.swift`, `Gate1AppModel+Onboarding.swift` | tag, X1, P30 | yes |
| X21 | #1022 | Playback transport, rate, mix audio and compact routing | `Gate1AppModel+PlaybackTransport.swift`, `Gate1AppModel+MixWithOtherAudio.swift`, `Gate1AppModel+CompactCommands.swift` and more | tag, X1, P7, P31 | yes |
| T1 | #995 | Audio preparation loop as its own type | New app-side type | X15 | yes |
| T2 | #954 | SkimBridgeController as its own type | New app-side type | X18 | yes |
| T3 | #957 | EpisodeMapPreparer as its own type | New app-side type | X18 | yes |
| T4 | #1015 | Imported podcast placement in its own app-side type | New app-side type | X16 | yes |
| T5 | #963 | Packet import coordinator as its own app-side type | New app-side type | X10 | yes |
| T6 | #969 | Bulk share preparation as its own app-side type | New app-side type | X9 | yes |
| T7 | #993 | Margin voice player and capture coordinator as app-side types | New app-side type | X8 | yes |
| T8 | #981 | Quick Access folder state as its own app-side type | New app-side type | X4 | yes |
| T9 | #997 | One shared-Margin listening state replaces two resume flags | New app-side type | X7, P18 | yes |

