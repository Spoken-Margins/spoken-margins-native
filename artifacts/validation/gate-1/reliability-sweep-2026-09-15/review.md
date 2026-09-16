# Podcast reliability investigation — September 15, 2026

## Outcome and evidence boundary

The exact Pod Save America failure is **unresolved**. The owner tentatively identifies Lock Screen skip on the Xcode-installed app and could not reproduce it. The supplied export cannot reconstruct that event. Three bounded repairs are implemented: playing-media skips preserve the current player, permanent podcast removal deletes its storage-ledger entry, and an automatic local transport event history survives restart without high-frequency samples displacing commands. Detailed sampling stays opt-in.

This is an implementation investigation, not product validation or a release handoff. No phone access, Library reset, install, commit or distribution was performed. Work is on `codex/provisional-next`, base `6432044bdc5ebff4691a69bee2699c309222ebac`, preserving the existing startup recovery, stale-clock and active-download protection changes. That SHA alone does not identify this dirty candidate or the owner's installed binary.

## Model used for the sweep

| Layer | Required invariant | Evidence path |
|---|---|---|
| Source/import | A feed entry resolves to the intended episode and a playable enclosure | Feed-entry import/resolver code; supplied item and source URL |
| Media transport | Skip moves from the current audible position on the same rendition; failed seeks remain recoverable | Lock Screen dispatch → SessionEngine → AVPlayer adapter; deterministic regression |
| Canonical state | Session time and Margin anchors survive navigation, interruption and restoration | SessionEngine position protection, seek acknowledgements and persistence tests |
| Offline storage | A live download owns a reservation; completion, cancellation, deletion and restart reconcile that ownership | Coordinator/ledger/delegate code and real SQLite/file tests |
| Execution/resources | Main-thread work is bounded; diagnostics do not become a new periodic workload | 500 ms progress loop, repository calls, recorder implementation |
| Observability | A later export retains command order, times and results, with source content excluded | Attached JSON and recorder restart/saturation tests |

Actors are the user/Lock Screen, main-actor app model, canonical session engine, AVPlayer, URLSession delegate/background restoration and storage-ledger actor. Their callbacks are independently scheduled. CPU/main-thread time, disk budget, network reachability and saved source/anchor identity are separate constraints. Priority is loss of playback/location or downloads first, followed by recoverability and measured responsiveness. A plausible network explanation alone does not close a defect.

## Supplied evidence

- Export timestamp: September 15, 21:20:37 UTC. Its saved developer capture spans September 14, 21:35:41–21:46:10 UTC.
- 1,195 of 1,200 events are routine samples. The five other events contain no command sequence for this report. The export's last seek (`1620792 ms`, accepted) is only a last-value field, not a timestamped reconstruction.
- The constant `device-diagnostics-20260908-C` is a instrumentation label, **not an installed commit identifier**.
- Export reports 4,999,317,401 ledger bytes versus 1,201,426,554 filesystem bytes. This warrants reconciliation; it does not prove which entries are stale, nor that one bug explains the difference.
- A bounded desktop HEAD request on September 15 reached HTTP 200 `audio/mpeg`, 91,342,051 bytes, with byte ranges, after eight redirects. Signed CDN query values were excluded from saved evidence. This establishes present reachability only. It does not test the phone's connection, AVPlayer seeks, past server responses or equivalence between streamed and downloaded ad insertions.
- Machine-readable summary: `evidence-summary.json`. The original attachment was read without modifying it; its digest is recorded there.

## Findings and disposition

### 1. Playing skips could replace the current stream — repaired, engine-verified

`skipMediaForward` and `skipMediaBack` used `playCurrentTarget`. A completed background download changes `playbackURLOverrides` while deliberately leaving the live stream alone. The next skip nevertheless applied that override and rebuilt AVPlayer. A remote stream and a separately fetched file need not have identical ad timing; that mismatch is a possible contributor, **not proof of the reported jump to 4:10**.

Playing skips now use the existing acknowledged media-seek transaction on the current player. Existing end-of-item handling, paused positioning and startup recovery are preserved. A regression supplies a background local override after 42 seconds, skips to 102 seconds and back to 87 seconds, and asserts no extra play or source switch. It failed before the repair (five assertions) and passes after it. Pause/resume continues to adopt the local override as the existing contract specifies; seamless edition equivalence across resume remains an open question.

### 2. Permanent podcast removal leaked its ledger entry — repaired, app-verified

`removeItem` deleted the file, audio assets and download record but omitted `podcast-offline-<itemId>`. This retains budget accounting for removed content and can retain protection metadata. The removal now deletes the matching owned asset. The regression seeds an actual file, download record, two audio assets and ledger entry, then checks all are removed. This prevents new instances on this path; it does not reconcile already-stale records on the phone.

### 3. Diagnostics miss intermittent failures — repaired, app-verified

Opt-in recording starts empty and 500 ms samples consume almost the entire 1,200-event ring. The owner consequently supplied yesterday's surviving recording with today's last-value diagnostics.

A separate default-on ring stores the latest 300 local events: transport commands/origin, requested seek and result, state changes, download state changes, and at most one active-playback checkpoint per 30 seconds. It excludes routine samples, scrubber display/drag events and rendering events. IDs/failures are hashed; no source text, raw source URLs or audio is added by these call sites. It restores history across launches and writes after each event on a serial utility queue. JSON encoding now runs off-main for disk persistence. There is no new sampling timer and no automatic upload. The detailed recorder remains optional and independent. Abrupt termination before a queued disk write completes can still lose the last event; cache purging can remove history.

Regression saturates the recorder with 1,500 samples, flushes, reconstructs it from disk, and verifies the command survives and the ring remains bounded. Settings explain the two modes. Export includes `playbackEvents` alongside the old optional recording.

### 4. Background download restoration loses reservation ownership — confirmed code defect, open (high priority)

The coordinator restores URLSession tasks and persistent download records, but `reservationsByItemId` starts empty. Completion requires a reservation in that dictionary; otherwise it deletes the completed file and reports “Offline storage was not reserved before download.” Persisted reservations already exist in the ledger, but restoration does not reconnect them. This explains a real restart-dependent failure path, not necessarily this episode's feed-start problem.

Required closure: restore live task/reservation ownership by persistent owner identity, handle expired/missing reservations deliberately, and test recreation while a background download is active through successful final adoption. Do not merely remove the storage guard.

### 5. Download failures and cancellation have incomplete cleanup — confirmed code defects, open (high priority)

An HTTP rejection or file-move failure calls `fail`, which only updates the record. URLSession may finish successfully at the transport level (`error == nil`), so `didCompleteWithError` returns without releasing its reserved space. Separately, removal does not invalidate an in-flight HEAD/reservation task; its continuation can still create/persist a download after removal. Callback identity is only `itemId`, so delete/re-add and late completion require explicit generation ownership. The active-task guard is cleared before asynchronous ledger adoption finishes, leaving additional lifecycle transitions to audit.

Required closure: a single terminal path that owns task identity, reservation release and state transition; deterministic tests for HTTP failure, failed adoption, deletion during preflight, delete/re-add and late callbacks. These fixes should precede claims that download reliability is resolved.

### 6. HEAD is a hard prerequisite and an exact size promise — confirmed limitation, incident link unproven

A server must accept HEAD and return a positive length before GET is attempted. The later file must fit that exact reservation. Servers that reject HEAD or omit length cannot download; independently personalized HEAD/GET responses may differ in size. Today's specific URL passed HEAD, so this is not evidence of today's startup root cause.

Required closure: a bounded streaming/download strategy with progressive or adjustable reservation accounting, plus tests for HEAD rejection, missing length and changed final size. Avoid solving this with an unbounded memory-buffered GET or an arbitrary large reservation.

### 7. Playback progress repeatedly scans persisted Margins — confirmed cost path, device impact unmeasured

The 500 ms main-actor playback loop reaches `syncMediaPositionFromAudio`, which runs `repairMediaPercentages` whenever a duration is available. That loads all session interjections even when duration has not changed; snapshot publication also loads interjections and AI jobs. Session position persistence runs whenever time advances. This is redundant I/O/decoding work on a latency-sensitive path. It is not a measured explanation for the user's freeze.

Required closure: repair historical percentages at a duration/revision change boundary, separate progress checkpoint durability from visual ticks, and count repository reads/writes before and after. Verify restore/termination recovery before reducing persistence frequency; do not trade responsiveness for lost location.

## Comparison, omission checks and stopping rules

- Compared stale UI state, wrong seek arithmetic, stream-to-file switching, provider reachability, download lifecycle failure and prior active-file eviction. The strongest new reproduced defect is the stream-to-file switch. Existing stale-clock/eviction repairs were preserved rather than represented as newly proved causes.
- Inspected both app and compact/Lock Screen skip entry points, active/paused/end handling, source resolution, transport overrides, background download initialization and completion, deletion/accounting, diagnostic capture/export and the progress tick.
- Counterexample: the strengthened skip test fails on the pre-repair implementation. Recorder tests distinguish command retention from merely bounding total events. Deletion checks storage metadata as well as file disappearance.
- Stop short of declaring incident resolution without a contemporaneous command/seek/transport trace or a reproduction on the affected installed source. No long audio download, broad UI route, release suite or device performance profile was performed.
- This is a sweep of the reported episode's surrounding reliability paths, not an exhaustive audit of every feature. AI generation, PDF extraction, Watch, provider services and product redesign were not expanded.

## Verification

- Before repair: strengthened transport regression executed once and failed five assertions (`skip-before.log`).
- First core run: two old assertions expected a new play on skip; updated them to require a seek and one original play, consistent with the intended transport repair (`core-after.log`).
- Final core run: **185 SessionKitCoreTests passed, zero failures** (`core-final.log`).
- First app build caught a Swift stored-property `Self` reference error; changed to the concrete model type before retry (`app-tests.log`). No test pass was claimed for that build.
- Focused iOS 26.5 simulator verification: **38 tests passed, zero failures/skips**, including 27 compact-control tests, eight download tests and three diagnostic tests (`app-tests-scrubber-filter.log`). The prior passing run is retained in `app-tests-final.log`; the final run adds the scrubber/sample exclusion assertion.
- Diagnostic schema and validator now recognize both exported histories and the new event kinds. Positive validation passed for both histories; an unknown event kind was correctly rejected. Test inventory passed.
- Whitespace/diff consistency check passed. Full app/release checks remain deferred under the active lane. Only the product owner can establish human validation.
