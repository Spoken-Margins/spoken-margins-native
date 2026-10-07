# Taking Gate1AppModel apart

*Spoken Margins · architecture plan · 7 October 2026 · written against `next` at `be9faf86`*

This is a plan for a refactor. Nothing here changes what a listener sees. Claims about the code cite names on `next` at `be9faf86`. Line numbers drift, so check the code before you rely on one. Issue numbers are in the table at the end.

---

## In one minute

1. **The model is one 16,386-line file that almost every change touches.** 26 of the last 60 merges to `next` (4 to 7 October) edited it. That is why branches collide and why the hot-file ratchet keeps failing pull requests.
2. **A plain split into eight extension files was tried on 2 October and left as a branch.** It moved lines, not ideas. It had to remove `private` from 338 declarations, every method still read the same state, and it conflicted with every open branch. Extension files are still the right tool for what is left at the end. They are not the right first move.
3. **The plan is four kinds of slice, in this order.**
   - **D, delete.** Remove code that nothing calls. About 700 lines.
   - **P, pure.** Move logic that needs no model state into SessionKit, where it gets tests that run on Linux. About 28 slices and 3,500 lines.
   - **X, extension files.** Move what is left into extension files, one per concern. After the Build 30 tag.
   - **T, types.** Give the biggest stateful loops their own types. After the extension file for that concern exists.
4. **The class keeps its stored properties, `init`, `deinit` and `didSet`s.** SwiftUI watches them, so they cannot move. The target is a model file of about 3,000 lines.
5. **The first slice is done.** The Listening Map JSON parser moved into SessionKit (#947). The model is 351 lines shorter, 18 new tests run on Linux, and the whole Linux suite passes (993 tests).
6. **Four calls are Cole's.** They are at the end of this page.

---

## 1. What is in the file today

The class runs from line 523 to line 16186. It has 677 methods (13,531 lines), about 420 stored properties (1,066 lines) and 158 `@Published` ones. The value types before the class take about 500 lines more.

The mapping pass read all of it. These are the concerns, with rough sizes. The sizes overlap at the edges and add up to about 14,500 of the file's 16,386 lines. The rest is blank lines and comments.

| Concern | Lines | Where it ends up |
|---|---|---|
| Stored properties, `init`, `deinit`, `didSet`s | about 1,600 | stays in the class |
| Library audio preparation (Supertonic) | 975 | X15, T1 |
| Importing sources (links, files, Quick Add, browser text) | 1,060 | P4, P12, X4, X5, T8 |
| Receiving shared Margins (packet import, placement, playback) | 1,230 | P18, P23 to P25, X7, X10, X16, T4, T5, T9 |
| Sending Margins (share sheet, packet export) | 850 | P21, P22, X9, T6 |
| Session export and batch export | 240 | X6 |
| Spoken and written Margins (capture, curation, Margins tab) | 780 | P13, X8, T7 |
| Playback transport, rate, skip, sleep timer, turns | 600 | P6 to P8 |
| Skim, episode maps, summary bridge, Listening Map generation | 960 | P1, P11, P19, X18, T2, T3 |
| Library list, trash, completion, navigation, chapter jumps | 700 | P10, X2, X3 |
| Following | 410 | P17, X11 |
| Settings, voices, speech preview, engine install, audio clients | 1,300 | X12, X13 |
| AI summary, discussion, provider (off in shipped builds) | 760 | P2, P15, X14 |
| Transcripts, source-window context, anchor evidence | 890 | P3, P16, P28, X17 |
| Item detail, feedback, bookmarks, bootstrap, onboarding, seeds | 725 | X1, X19, P27 |
| Watch bridge (never compiled) | 290 | D4 |
| Dead code and copy-paste | 650 | D1 to D3, D6, P9 |
| Value types before the class | 500 | X0 |

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

1. **Now, in parallel: D1 to D3, D6 and all `ready` P slices.** They sit in different regions, so several can run together. `P19` only adds tests and touches no model code.
2. **After the Build 30 tag, in a quiet window: X0 and X1, then the X slices one at a time.** Each X slice names the P slices it waits for.
3. **After each X slice: the T slice for the same concern.**
4. **Anything that needs Cole waits on his answer** (D4, D5, P26) and does not block the rest.

Open Build 30 pull requests touch some of these regions. A slice in the same region waits until that pull request has merged, because Build 30 does not wait for Build 31.

| Open PR | Region | Slices to hold |
|---|---|---|
| #935 podcast placement | imported podcast placement | X16, T4 |
| #938 Timeline Back | navigation | X3 |
| #896 source-window jobs | source-window context | X17, P16 |
| #906 Add Margin while a Margin plays | spoken Margin capture | X8, T7 |
| #931 export folder settings | export and share folders | X6, X9 |
| #903 diagnostics IDs | diagnostics export | P5 |

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

Two of these are filed as bugs. The rest are observations I read in the code and did not reproduce or file.

1. #949: curly quotes around Listening Map keys and strings do not repair. Filed.
2. #950: heard-audio files for a streamed Margin stay in `Caches` when the context is already ready. Filed.
3. A background-task expiry saves the episode-map job as cancelled, so fingerprinting restarts from landmark 0 next time. Not filed.
4. `enqueueStartupAudioPreparation` runs in a Task with no handle, so its cancellation checks never fire. Not filed.
5. `refreshAudioPreparationPresentation` deletes SQLite job rows as a side effect of building a list. Not filed.
6. The filter menu says "Pdf" where the model says "PDF" (`ExperienceLibraryScreen.swift:386`). P10 asks Cole to pick one.

---

## 8. How we will know it worked

1. **The model file's size.** 16,386 lines at the start. 16,035 with the first slice. The target is about 3,000.
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

{{TABLE}}
