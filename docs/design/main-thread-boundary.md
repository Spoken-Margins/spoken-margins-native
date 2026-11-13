# The main-thread boundary for the store (#2507, #2509, #2256)

A design note, 2026-11-12, for run #4187. It changes no code. It settles where store work may run, how the prepared-audio transaction persists, how progress writes are coalesced, and whether a play with no open before it should wait or freeze. It ends with the mechanical pieces that finish the work, one Sonnet PR each. They are listed here and were filed on 2026-11-13 as #4219 to #4223: the owner moved #2507 and #2509 to Later on 2026-11-02 until the sharing loop (#3216) is done.

Every count below was taken on `main` at `7aec51722` (2026-11-12). Line numbers drift; check the code before relying on one.

## Where things stand

The work these issues opened is mostly done. What is left is small, and the main decision is to stop, not to start a rewrite.

- **The store.** `SQLiteSessionStore` (`Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift:16`) is a synchronous, thread-safe class. It has one write connection behind an `NSRecursiveLock` (`connectionLock`, :22) and a pool of up to six read-only WAL connections (`readConnectionLimit` :19, `ReadConnectionPool` :2199), so a read never waits for the write lock. It has 178 public methods.
- **The async facade exists.** `StoreReader` (`StoreReader.swift:18`) runs a closure on a detached task and hands the result back: `read` :24, `readLatest` :43 (an old answer never overwrites a newer one), `readInOrder` :63 and `enqueueInOrder` :73 (read-modify-write in tap order). It was added for #2507 (#2629) and call sites use it today, for example `Gate1AppModel+PublisherAudio.swift:63`.
- **The guard.** `scripts/main_thread_reads.py` finds store calls, file reads and synchronous AVFoundation calls in main-actor code. It printed `ok (454 baselined rows, 1079 files)`: 424 baseline entries with a total count of 454. By class:

  | Class | Entries |
  |---|---|
  | store-heavy-decode | 110 |
  | store-read | 98 |
  | unlabelled-main-task | 93 |
  | file-io | 63 |
  | store-write | 27 |
  | av-sync | 25 |
  | store-whole-table-read | 8 |

  Of the 243 store entries, 236 carry a reason they stay (most begin "Stays", with a measured cost or a rule), and **7 still say TODO**. They are the whole remaining store list:

  | File | Function | Call | Issue | Recorded cost |
  |---|---|---|---|---|
  | `PodcastDownloadCoordinator.swift:338` | `restoreRecords` | `loadPodcastDownloads` (whole table) | #2507 | once per launch, grows with the Library |
  | `EpisodeMapPreparer.swift:119` | `prepare` | `loadEpisodeMapPreparationJobs` | #2507 | a few rows by index |
  | `Gate1AppModel+EngineAttachOffMain.swift:90` | `attachPreparedTextAudio` | via `SessionEngine.attachPreparedTextAudio` | #2509 | 7.7 s to 9.9 s on a 1.1 MB book (only when no engine exists yet) |
  | `Gate1AppModel+FileImport.swift` | `importTextItem` | `store.seed` | #2509 | 0.44 ms at 20 KB, 153 ms at 8 MB |
  | `Gate1AppModel+FileImport.swift` | `importTextItem` | `store.saveListeningMap` | #2509 | 0.41 ms at 20 KB, 3.9 ms at 8 MB |
  | `Gate1AppModel.swift:1351` | `start` | via `SessionEngine.startSession` | #2256 | 5 reads; plus the text projection when no open came first (below) |
  | `Gate1AppModel+MarginCapture.swift` | `pauseSourceOnTap` | via `SessionEngine.pauseSourceForInterjection` | #2256 | 0.01 ms with nothing to pause; a playing source unmeasured |

- **Raw call sites.** A text count of direct store calls in `App/` (receivers `store`, `sessionStore`, `requireStore()`, `skimStore`, `libraryStore`) finds 179 reads and 83 writes outside tests. That count includes calls already inside `StoreReader` closures and misses calls through `$0` or `repository`, so it is a size, not a to-do list; the guard is the to-do list. The files with the most are `PodcastDownloadCoordinator.swift` (20, mostly writes already on its serial `rowWriter` queue), `Gate1AppModel.swift` (19), `Gate1AppModel+LibrarySeeding.swift` (16), `Gate1AppModel+TrashUndo.swift` (15), `ImportedPodcastPlacementCoordinator.swift` (12) and `EpisodeMapPreparer.swift` (12). The script and the per-file lists are kept outside the repository with the run's notes.
- **The engine.** `SessionEngine` (`SessionEngine.swift:8`) is a plain synchronous class that the app drives from the main actor. Its files call `repository.` 135 times.
- **The hot files.** `scripts/hot_file_ratchet.py`: `Gate1AppModel.swift` is 3018 lines against a ceiling of 3018, and `Gate1RootView.swift` 582 against 582. There is no headroom; every piece below must move lines out of those files, never in.

## 1. The shape of the boundary: the async facade

**Decision: `StoreReader` is the boundary.** The store stays a synchronous, thread-safe class. Main-actor code reaches it through `StoreReader`, one closure per screen action. A screen that needs several reads puts them in one closure (a "loader" is simply that closure, given a name when it is reused). `SessionEngine` stays synchronous.

The options weighed:

1. **A store actor.** Every one of the 178 methods becomes `async`, and so does every caller, including the engine's 135 synchronous repository calls and the synchronous transaction closure in `withSessionTransaction`. An actor also runs one call at a time, which throws away the six-reader WAL pool that lets reads run beside the writer today. What it would buy is compile-time enforcement, which the text-matching guard only approximates. That is real, but it costs the largest change in the codebase for a store whose remaining main-thread work is seven rows. Rejected.
2. **The async facade (picked).** It already exists, is already adopted, and lets each call site move alone, which is how the guard's rows have been worked down so far. It keeps the reader pool. Its known gap, that two unstructured `Task`s may reach the store in either order, is already closed by `enqueueInOrder` (#3331).
3. **Per-screen loader types.** These are not a third shape: they are the facade, used once per screen. Make a named loader only when two call sites share the same set of reads.

**Rule for new code.** Main-actor code never calls a store method directly. It calls `StoreReader(store).read { … }`, or `readLatest` when a screen may ask again before the answer comes back, or `enqueueInOrder` for a write that must keep tap order. The guard rejects a new direct call unless it is added with `--accept "reason"` and a measured cost.

**When a store call may stay on main.** Only when it is cheap by the meter and moving it would cost more than it saves: a single row by primary key, a write the next main-actor line depends on, or launch-time UI-test seeding. Each such call keeps its baseline row with the measured number in its reason. This is #2256's Done-when item 3 ("each justified and cheap by the meter"), and 236 rows already meet it.

## 2. Persisting after the prepared-audio transaction, and coalescing progress writes

### The transaction

`PreparedAudioEnqueue.withCurrentManifest` (`PreparedAudioEnqueue.swift:38`) runs inside `withSessionTransaction`. It holds the write connection and marks the thread as the transaction's owner, re-reads the manifest and the item, checks they still match, then runs the caller's writes. Its closure is synchronous on purpose.

**Rule:**

1. The whole transaction (re-check and writes) runs off the main actor, in one synchronous call, never split by an `await`. `PreparedTextAudioPersister.persistAssembly` (`EngineAttachPersisters.swift:62`) is the pattern: it runs on a background task and returns a value, `.attached(PersistedPreparedTextAudio)` or `.dropped`.
2. Back on the main actor, only the in-memory half runs: `SessionEngine.attachPreparedTextAudio(_:replaceActivePlayback:)`, which reads no store row (`EngineAttachPersistersTests`), then the screen updates.
3. `.dropped` means a Stop, a new voice or an edit landed meanwhile. Nothing was written, and the caller discards the audio with no failure shown.

What this rule protects against:

- **A kill mid-write.** The re-check and the writes are one SQLite transaction in WAL mode, so a kill leaves either all of it or none. The item never points at a timeline that was not saved.
- **A second writer.** A Stop or a new voice that commits between the render and the save is seen by the re-check, because the re-check runs inside the same transaction as the write. Splitting them with an `await` would reopen exactly that gap (#2134), which is why the rule forbids it.
- **An old build opening the database.** Nothing here changes a table or a column.

One gap the rule does not close: a Stop that lands after the transaction commits but before the main-actor attach is not re-checked. The audio is already saved for the right text, so nothing is corrupted; the question is only whether it should still be attached. It is listed under "Not settled here".

One caller still breaks the rule: `attachPreparedTextAudioOffMain` falls back to the synchronous `attachPreparedTextAudio` on main when no engine exists yet (`Gate1AppModel+EngineAttachOffMain.swift:128`), which costs 7.7 s to 9.9 s on a 1.1 MB book. Piece 2 below closes it.

### Progress writes: one rule

**Rule:**

1. A progress tick updates the in-memory value and the screen on every tick.
2. The database gets that tick at most once every 5 seconds per key.
3. Anything that is not a tick writes at once and restarts the 5 seconds: pause, finish, failure, an item switch, going to the background, termination.

`ProgressWriteGate` (`SessionKit/ProgressWriteGate.swift:8`) is that rule as a type.

Where each stream stands:

| Stream | Tick | Write today | Thread | Change |
|---|---|---|---|---|
| Playback position | 500 ms (`Gate1AppModel.swift:886-895`) | Session row at most every 5 s (`SessionEngine.swift:554`, :671-680); flushed at once on pause and other non-tick syncs (:682) | main | none: keep on main with the engine's own timer, which follows the same rule |
| Download bytes | per chunk | `ProgressWriteGate` at 5 s (`PodcastDownloadCoordinator.swift:37`) | serial `rowWriter` queue (:42) | none |
| Import | none found | written once at the end | main for pasted text (`importTextItem`) | none for ordinary sizes; see piece 3 |

**Why playback position stays on main.** Cost: it is one small row by primary key, written at most 0.2 times a second while playing, and moving it would buy almost nothing. Ordering is not the reason. Streamed turns already write Session rows on a writer queue with ordered flushes (`SessionEngine.swift:2675-2687`), so that could be done; it is just not worth doing for this row. The engine keeps its own 5-second timer (`lastProgressWriteAt`, :554-682). It records a write only after the save succeeds, which `ProgressWriteGate.shouldWrite` does not (it counts the write before it happens), so the two are not swapped.

**What a kill or a long listen costs.**

- A kill loses at most about 5.5 seconds of place (5 s between writes plus one 500 ms tick), the same as today.
- A 2-hour podcast makes about 1,440 position writes, against 14,400 if every 500 ms tick were written.
- A download killed mid-way is set back to waiting on the next launch and fetched again (`restoreRecords`, :357), so a skipped progress write loses no stored audio, only a progress figure.

## 3. A play with no open before it: neither a wait nor a freeze

`Gate1AppModel.start` (`Gate1AppModel.swift:1351`) calls `SessionEngine.startSession` (`SessionEngine.swift:187`) on the main actor. Opening an item first builds the listenable text off main and keeps it (#2256), so a play after an open is cheap. A play with no open before it (from a Library row's play button, a widget, a chapter jump, or a play after the text changed) still pays two more costs on main:

1. Projecting the whole text for speech.
2. For a PDF, reading the document and building its listenable text.

Every play of a text item, opened first or not, also pays the rest of the cache lookup on main, as the measurement below shows, and a save on main when the lookup hits (`SessionEngine.swift:3823-3826`).

The baseline row records 282 ms for one fixture article (host debug build). #2256's comment of 2026-11-11 names two ways out: await a prewarm before the play (a visible delay on the tap), or make the engine's start async. The measurement below shows a third: most of the work the start does on main produces nothing, and can simply stop.

**The number that decides it.** The main-thread time of `start.prepareAudio`, measured against #2256's own line: "no `main.hang` over 250 ms on open, play, pause, close, background or return".

How it was measured:

- A throwaway release-build executable on the maintainer's Mac called the engine's own `SystemTextAudioPreparationClient.prepareTextAudio` with `allowsSynchronousRendering: false`, as the engine's client is built (`Gate1AppModel.swift:2547`).
- It used a repeated news paragraph with numbers and a link, 5 runs per size.
- The first run of each size is cold (the projection is not kept yet), and is the "max" column. The other runs find the projection kept, as a play after an open does.

| Text | Characters | Median, projection kept | First run, cold | Projection alone |
|---|---|---|---|---|
| 20-minute article (3,000 words) | 18,270 | 67 ms | 70 ms | 41 ms (at this size the projection was not kept between runs) |
| 2-hour narration (18,000 words) | 113,970 | 160 ms | 430 ms | 0.3 ms |
| Book (100,000 words) | 634,230 | 890 ms | 3,204 ms | 1.9 ms |
| Long book (250,000 words) | 1,586,880 | 2,264 ms | 10,931 ms | 4.7 ms |

What it shows:

1. **The projection is not the whole cost.** With the projection kept, `prepareTextAudio` still costs 160 ms for a 2-hour text and 890 ms for a book. Before it looks for the cached render, it splits the whole text into segments and hashes all of it for the cache key (`AudioAdapters.swift:399-414`). That runs on every start, including a play after an open. The split between the two was not measured.
2. **A book crosses 250 ms on a Mac**, kept or not. A phone is slower than this Mac (INFERRED: the ratio was not measured here), so a 2-hour text very likely crosses it there too.
3. **The cache-hit start was not timed.** On a hit, `prepareTextAudio` also decodes the cached render's JSON (about `AudioAdapters.swift:446`), and the engine rewrites the item and its timeline on main through `applyPreparedTextAudio` (`SessionEngine.swift:3852`). That is the same kind of store write as the no-engine attach measured at 7.7 s to 9.9 s for a 1.1 MB book, but the start's own rewrite was never timed.
4. **Freezing is not an option above about 2 hours of text.** A 10.9-second cold start on main is long enough for a listener to leave and for iOS to end the app, which is #2256's own description of the harm.

**What the start's lookup is for.** On the phone it finds almost nothing:

- The engine's client never renders (`allowsSynchronousRendering: false`, `Gate1AppModel.swift:2547`), so it can only find a render someone else wrote to its cache.
- In production nothing does. The background prewarm that would write it, `preparedTextAudioPrewarmHandler`, defaults to nil (`Gate1AppModel.swift:600`) and the app builds its model without one (`SpokenMarginsApp.swift:89`), so `prewarmTextAudioForOnDeviceVoice` returns early (about `Gate1AppModel.swift:2563`); its comment says production playback must stay on the immediate path. The other users of `SystemTextAudioPreparationClient` write elsewhere: episode summaries keyed by asset (`EpisodeMapPreparation.swift:156`) and a scratch folder (`WrittenMarginReader.swift:138`).
- So on device the lookup misses every time, apart from cache files left by older builds. On a miss, `prepareGeneratedTextAudioIfAvailable` returns the item unchanged (`SessionEngine.swift:3823-3825`), and the play uses live speech. The whole-text split and hash buy nothing.
- Renders that do reach an item on device (the on-device voice's startup preparation) attach through `attachPreparedTextAudioOffMain` (`Gate1AppModel+AudioClients.swift:163`), not through this lookup. Piece 2 takes that path's last main-thread save away.

What a hit does where hits happen (host tests and Mac tools, whose clients render synchronously): `writePrepared` (`EngineAttachPersisters.swift:96-115`) rebuilds the timeline's chapters from the current listening map and flips `needs_listening_map` to `ready`. Neither `ListeningMapPersister` (:15-22) nor `attachListeningMap` (`SessionEngine.swift:1303`) refreshes the chapters on a generated timeline, so today a hit after a later map is what brings the chapters up to date. The cache key also includes the voice and the rate (`AudioAdapters.swift:639-643`), so a hit needs the same voice and rate as the render.

**Decision: neither a wait nor a freeze. The start stops doing the full-text work.** For a text-audio client that cannot render synchronously, `startSession` makes no `prepareTextAudio` call:

1. An item that carries a prerendered render whose file exists plays it as it is, with no lookup and no rewrite. A missing file is already caught by `discardUnavailableGeneratedTextAudio` (:192).
2. An item with no render plays live speech at once, as every play does on device today.
3. A client that can render synchronously (host tests, Mac tools) keeps today's path unchanged, including the chapter refresh on a hit.

The guard goes inside `prepareGeneratedTextAudioIfAvailable` (`SessionEngine.swift:3816`), not in `startSession`, so it also covers `playSourceFromBeginning`, which calls that function directly (`SessionEngine.swift:1573-1575`).

`TextAudioPreparationClient` (`Protocols.swift:375`) gains one property saying whether it renders synchronously, defaulting to true, which keeps the existing synchronous-fake test valid (`SessionKitCoreTests.swift:3929`). `SystemTextAudioPreparationClient` answers it from `allowsSynchronousRendering`.

A simpler option was weighed: `makeTextAudioPreparationClient` could return nil on device, so the engine has no text-audio client at all. The engine uses its client only in this one function (`SessionEngine.swift:3818`), and the app builds that client only for the engine (`Gate1AppModel.swift:2533`), so it would work and would shrink `Gate1AppModel.swift` by a few lines. It was not picked because it can only be proved in the app-hosted lane, while the property puts the decision in SessionKit, where a host test proves it. Either is acceptable; piece 4's reviewer may prefer the nil route.

Why this, rather than a wait or an async start:

- **It covers every play route at once.** All of them reach `prepareGeneratedTextAudioIfAvailable`, through `startSession` or directly, so the fix inside the engine needs no list of entry points: the Library row, the lock screen, a chapter jump (`Gate1AppModel+ChapterNavigation.swift:98`), play from the beginning (`SessionEngine.swift:1574`), a pasted assistant reply (`Gate1AppModel+Summary.swift:214`), and the engine's own starts (:291, :1032).
- **It adds no state.** There is nothing to cancel, no pending request, and no new state in the engine or the app model.
- **Behaviour on device does not change.** Every play there misses today and plays live speech; after the change it plays live speech without the miss. The one exception is a cache file left by an older build, which stops being found; the render path that serves today's builds attaches off main and is untouched. Where hits happen (synchronous clients), nothing changes, so the chapter refresh a hit does there is kept.

A wait would have needed a cancel at every place a play can be ended or replaced. Two fresh reviews of a wait design found those places hard to list correctly: Pause and the lock screen call `start()` again while nothing is playing, and several routes never pass through `start()`. An async start would have split the engine's start across a suspension point, in effect a new playback state machine.

**What is left: a PDF played with no open.** Building a PDF's listenable text without an open still reads the document on main (the `Gate1AppModel.start` baseline row). That cost was not measured here. Piece 5 measures it. If a long PDF is over 250 ms, it needs its own design, and that design must handle the play routes and cancel points listed above.

**What would show this is wrong.**

- Field hang reports labelled `start.prepareAudio` stay above 250 ms after piece 4 ships.
- Or a production build turns out to write the engine client's cache after all (for example a prewarm handler is wired in later). Then the lookup does find renders on device, and skipping it would drop them and their chapter refresh; the design would need a hit path off main instead.

## 4. What must not change

1. **The database.** No piece changes a table, a column, an index or `user_version`. The previous build still opens the database, because nothing in it changes. A piece that finds it needs a schema change stops and asks for a design.
2. **No new playback state machine,** and no new "should the source resume" flag. The engine stays synchronous, and section 3 adds no state anywhere.
3. **No growth of `Gate1AppModel`.** `scripts/hot_file_ratchet.py` stays green: `Gate1AppModel.swift` ends each piece at or under 3018 lines, and `Gate1RootView.swift` at or under 582. New logic goes in a focused type, in SessionKit when it can be host-tested.
4. **The guard only goes down.** `scripts/main_thread_reads.py` stays green. Each piece removes its own baseline row with `--update`, or rewrites a TODO reason to "Stays" with a measured number; no piece adds a row.
5. **Packets.** Nothing here touches export or import formats.
6. **The hang probe's labels.** The `start.*` labels in `startSession` and `start.prepareSource`, `start.itemDetail` and so on in `start` stay, so field reports keep naming the step.

## 5. The follow-on pieces

Each piece is one Sonnet PR. Every piece edits `scripts/main_thread_reads_baseline.json` (it removes or rewrites its own row), so they run one at a time, in this order. Filed 2026-11-13 on the owner's yes: piece 1 is #4219, 2 is #4220, 3 is #4221, 4 is #4222, 5 is #4223. Pieces 3 and 5 are `ready` (no app code); 1, 2 and 4 carry `later` until the sharing loop #3216 settles (owner, 2026-11-02).

1. **Read the episode-map job off main.** `EpisodeMapPreparer.prepare` (:119) reads `loadEpisodeMapPreparationJobs` through `StoreReader`. A pending flag is set before the await, so a second `prepare` during the read does not start a second run (today `guard task == nil` at :106 would let it through).
   - Files: `EpisodeMapPreparer.swift`, the baseline.
   - Proof: an app-hosted test that calls `prepare` twice while the first read is held, and sees one run; one where a job cancelled during the read is skipped; the guard row gone.
   - Needs the Mac: yes (T2, app-hosted XCTest).
2. **No synchronous attach when the engine is missing.** In `attachPreparedTextAudioOffMain` (`Gate1AppModel+EngineAttachOffMain.swift:120`), install the engine first when there is none, then take the off-main persister path. The 7.7 s to 9.9 s main-thread save is gone; the in-memory attach stays on main.
   - Before changing it, the builder measures `makeEngine` on the Library fixture. If it is not cheap by the meter, the builder stops and reports the number.
   - Files: `Gate1AppModel+EngineAttachOffMain.swift`, an app-hosted test, the baseline.
   - Proof: an app-hosted test of `attachPreparedTextAudioOffMain` with no engine, asserting the store save ran off the main thread (it fails today, because the fallback saves on main) and the audio is attached; the guard row gone.
   - Needs the Mac: yes (T2, then T3 for the prepared-audio tests).
3. **Settle the rows that stay.** No code moves.
   - `importTextItem`'s `seed` and `saveListeningMap` cost under a millisecond at ordinary size, and 153 ms only for an 8 MB paste. Their rows change from TODO to "Stays" with those numbers.
   - `PodcastDownloadCoordinator.restoreRecords` (:338) runs inside the coordinator's synchronous `init` (:92), before `getAllTasks` (:93). Moving it off main would leave a window with no records, in which a background download finishing (:773-786) finds no record and deletes the file (:602-606), and `register` (:218) starts over. So it is measured instead: `loadPodcastDownloads` on 1,000 rows, in a host test. If it is under 50 ms, the row becomes "Stays" with the number. If not, it needs its own design (restore as a task that delegate callbacks, `register` and `status` wait for), not a mechanical piece.
   - `pauseSourceOnTap` gets the measurement its row lacks (a playing source, on the Library fixture, in `PlayAndRecordStartCostTests`). The row is then marked "Stays" if under 250 ms, or becomes its own piece if over.
   - Files: the baseline, `PlayAndRecordStartCostTests.swift`, a SessionKitPersistence cost test.
   - Proof: the printed cost lines, and the guard green.
   - Needs the Mac: no (host only).
4. **The start does no full-text work** (section 3).
   - What changes: `TextAudioPreparationClient` gains a "renders synchronously" property, default true, and `SystemTextAudioPreparationClient` answers it from `allowsSynchronousRendering`. When it is false, `prepareGeneratedTextAudioIfAvailable` (`SessionEngine.swift:3816`) returns the item with no `prepareTextAudio` call and no save, which covers both `startSession` and `playSourceFromBeginning`.
   - Files: `Protocols.swift`, `SessionEngine.swift`, `SessionKitAudio/AudioAdapters.swift`, a SessionKit test, the `Gate1AppModel.start` baseline row's reason.
   - Proof, host tests with a recording fake client that cannot render synchronously and a counting repository:
     - a start of an item with an attached render makes zero lookups and zero item or timeline writes, and plays the render;
     - a start of an item without one makes zero lookups and plays live speech;
     - `playSourceFromBeginning` with the same fake makes zero lookups;
     - a fake that renders synchronously keeps today's calls.
     - With the property added and the engine unchanged, the first three fail, because the engine still looks up and rewrites.
   - Then the gated `PlayAndRecordStartCostTests` (`SESSIONKIT_START_COST=1`). Today it builds the engine with no text-audio client (`PlayAndRecordStartCostTests.swift:53`), so `start.prepareAudio` already returns at the first guard and shows nothing. Wire in a client that cannot render synchronously and a 100,000-word item, and record the `start.prepareAudio` time before and after the change in the PR.
   - Then journey J1 (Listen to an article) in `docs/journeys.md`, on a book-length article played from the Library row without opening it, with the hang probe showing no `start.prepareAudio` over 250 ms. A 20-minute fixture article would pass even today, so the journey must use a long one.
   - Needs the Mac: yes (T2 compile, T3, and the journey).
5. **Measure a PDF played with no open.** Time `start.prepareSource` and the listenable-text build for a 300-page PDF in a host test.
   - Under 250 ms: the baseline row's reason records it, and #2256 item 3 is met for plays.
   - Over: it needs its own design (section 3), not a mechanical piece.
   - Files: a SessionKit cost test, the baseline.
   - Needs the Mac: no.

Order: 1, 2, 3, 4, 5. Piece 2 goes before 4 because both change how prepared audio reaches the engine. After piece 5, the store part of the guard has no TODO rows left. #2507's and #2509's Done-when can then be checked against the guard, and #2256's item 3 against the baseline reasons.

## Not settled here

- The 93 `unlabelled-main-task`, 63 `file-io` and 25 `av-sync` rows. They are main-thread work, but not store work, and need their own pass. #2255's 20-second hang on a 77-minute file came from AVFoundation, not the store.
- Whether a Library row's play button should open the item first. That is a design call about the Library screen, not about the boundary.
- A Stop between the prepared-audio commit and the main-actor attach (section 2). The audio saved is correct for its text; whether the attach should then be skipped needs its own look at how `finishAttachingPreparedTextAudio` treats a stopped preparation.
- Moving the download restore off main. It needs restore as an awaited task (piece 3), and is a design of its own if the measurement says it is slow.

## Appendix: the start-cost measurement

The section 3 table came from this throwaway executable, run once with `swift build -c release` in a scratch package that depends on `Packages/SessionKit` by path. No artifact was kept; rerun it to check. Its `main.swift`, without the sample paragraph (any prose with numbers and a link will do):

```swift
import Foundation
import SessionKit
import SessionKitAudio

let paragraph = "…"   // one news paragraph, about 140 words, ending in a blank line
let dir = FileManager.default.temporaryDirectory.appending(path: "startbench-\(getpid())")
let client = SystemTextAudioPreparationClient(outputDirectory: dir, allowsSynchronousRendering: false)
func ms(_ body: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds; try body(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}
for words in [3_000, 18_000, 100_000, 250_000] {
    let text = String(repeating: paragraph, count: max(1, words / paragraph.split(whereSeparator: \.isWhitespace).count))
    var runs: [Double] = [], projection: [Double] = []
    for i in 0..<5 {
        runs.append(try ms { _ = try client.prepareTextAudio(itemId: "bench-\(i)", title: "t", text: text) })
        projection.append(ms { _ = SpeechTextNormalizer.projectForSystemSpeech(text) })
    }
    print(words, text.count, runs.sorted()[2], runs.max()!, projection.sorted()[2])
}
```

Checked: `SQLiteSessionStore.swift:16-99, 2097, 2199`; `StoreReader.swift:1-80`; `PreparedAudioEnqueue.swift:38`; `EngineAttachPersisters.swift:40-110`; `ProgressWriteGate.swift:1-30`; `SessionEngine.swift:187-228, 554-682, 1303, 1573-1575, 3816-3852`; `AudioAdapters.swift:330-450, 639-643`; `EngineAttachPersisters.swift:96-115`; `Gate1AppModel.swift:600, 631, 2533-2563` (ranges only); `SpokenMarginsApp.swift:89`; `PlayAndRecordStartCostTests.swift:53`; `Gate1AppModel.swift:1351-1375` (range only); `Gate1AppModel+EngineAttachOffMain.swift:85-160`; `Gate1AppModel+PublisherAudio.swift:38-63`; `PodcastDownloadCoordinator.swift:330-350`; `scripts/main_thread_reads_baseline.json`; issues #2256 (including the comments of 2026-10-20 and 2026-11-11), #2507, #2509 and #2255, all on `main` at `7aec51722`.
