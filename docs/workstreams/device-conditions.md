# Device conditions: what a PR turns into host tests (#3899)

Most phone-found bugs were not about a screen. They were about the phone's state when the listener used the app: locked, away, relaunched, offline, on AirPods. A host test can put the code in that state if the code has a seam for it. This page is the short list of those states, so a builder or a design pass names the ones a change meets and writes a test for each before the phone does.

**Source.** `docs/workstreams/device-conditions-bugs.tsv` classes every `found-on-phone` + `bug` issue (144 on 2026-11-10) under one row, or under `none:<why>` when no device condition was behind it. 70 of the 144 (49%) sit under a row. `scripts/device_conditions.py` counts them.

**The report's 51.** The what-catches-what report's 51 bugs (2026-11-09) are all in the list, and saved in `device-conditions-report-51.txt`. Nine of them had `found-on-phone` but no `bug` label, so their lines were added by hand. `scripts/device_conditions.py --only docs/workstreams/device-conditions-report-51.txt` counts them: 31 of the 51 (61%) sit under a row. The report counted 29 (57%) with a device-condition or performance trigger. The two readings differ on 8 bugs, which is the report's own limit before its trigger table moves:

1. Three it called data or contract edges sit here under a row: #2097 (`main-thread`), #2118 (`long-source`), #3041 (`web-packet`).
2. Two it called plain flows sit here under a row: #3489 (`lock`), #3753 (`store`).
3. Three it called device conditions have no row here: #2856 (cause unknown), #3243 (a Watch design call), #3674 (a Watch layout fault).

## How to use it

1. **Builder.** A PR that touches playback, capture, import, sharing, the Library read path or a background job names, in its description, the rows below that its change can meet, and the host test for each, or says why a row does not apply. The test fails without the fix (`AGENTS.md`, Verification).
2. **Design pass.** The **Design** comment lists the rows its flow meets (the one line added to the contents in `docs/decisions.md`, 2026-11-09), so the builder starts with them.
3. **A bug the phone finds** gets its row in `device-conditions-bugs.tsv` in the fix PR. `scripts/device_conditions.py --unlisted` lists the ones not yet there. It sees only issues labelled `bug`; a phone-found bug without that label gets its line by hand.

## The rows

Each row: the condition, how a host test expresses it, the seams that exist today (under `Packages/SessionKit/Sources/`), and two bugs it would have caught.

| Row | Condition | How a host test expresses it | Seams today | Examples |
| --- | --- | --- | --- | --- |
| `lock` | Phone locked or screen off while something runs | Drive the coordinator with the "locked / not active" input and assert audio, recording and saves still finish | `SessionKit/HandOverBackgroundHold`, `InterruptionBackgroundHold`, `LockedMarginIntentReport`, `LiveSessionFileWorker+Resume` | #1762 (repeats first words when locked), #3489 (spoken Margin lost when the phone locks) |
| `background` | App left mid-flow, or iOS suspends or kills it | Inject the app-phase and a fake clock; assert what continues, what pauses and that nothing starts late | `SessionKit/BackgroundChunkSeam`, `BackgroundPreparationPlanner`, `InterruptionResumeRetrier` (injected sleep and clock) | #854 (silent if you leave right after Play), #2626 (killed in the background after a seek) |
| `relaunch` | App relaunched mid-flow; yesterday's state is all there is | Write the state with a real temporary SQLite store, build a new model over the same file, assert resume, order and progress | `SessionKit/PreviousRunExit`, `LaunchHistory`, `MarginCaptureResume`, `RecordingDraftJournal`; tests `ResumeAfterRelaunchTests`, `RestoredSessionOrderTests` | #2186 (resumed at 42% after 80%), #1680 (saved audio never played again after restart) |
| `store` | Store busy or not open yet; data not loaded when the screen draws | Hold a read connection or a write lock in the test and call the screen's read; assert it neither blocks nor shows the wrong first state | `SessionKitPersistence` read pool and `SQLiteConnectionLockTests`, `SessionKit/LibraryReadSnapshot` | #2103 (one locked connection stalls reads), #3753 (friends' old Margins show first, then snap away) |
| `main-thread` | Work on the main thread a screen waits for | Run the read or build off the main actor through `MainThreadOffload`; fail a test that calls the synchronous path; `scripts/main_thread_reads.py` keeps new ones out | `SessionKit/MainThreadOffload`, `MainThreadHangProbe`, `scripts/main_thread_reads.py` baseline | #2073 (item screen freezes after a map), #2255 (downloaded mapped podcast freezes 10–20 s) |
| `network` | Offline, a slow server, or a server that says no | Hand-drive `ConnectivityProviding` and a fake transport; assert the message, the retry and that nothing is lost | `SessionKit/ConnectivityProviding`, `PendingHandoffNetworkRetry`, `RetryCooldown` | #1546 (Safari import lost offline), #933 (stream took three tries to start) |
| `route` | Audio route change or interruption: AirPods, Bluetooth, AirPlay, a headphone button, another app taking audio | Feed the interruption, route and remote-command events to the coordinator; assert resume, the Margin that is recording and the one that is playing | `SessionKit/InterruptionEnd`, `InterruptionResumeRetrier`, `CaptureInputRouteCache`, `MarginRecordingInterruption`, `HeadphoneDoublePressPolicy`, `RecordingInputPolicy` | #1434 (AirPods interruption leaves it paused), #1030 (a headphone click ends the Margin) |
| `web-packet` | A packet or text that arrived from the web page or the Safari extension, not from the app | Use a packet fixture shaped like the web page's (sender clock time only, no fingerprint), or a Safari-extension payload fixture (page text, title, URL); import it and assert placement and playback | `SessionKit/BrowserTextImporter`, `Gate5BrowserTextHandoffStore`, `PackageImportPolicy`, `SharedMarginPlacement`; fixtures in `Contracts/fixtures` and `docs/sharing-test-kit` | #3041 (web-packet Margins never auto-play), #658 (Safari extension on a PDF imports viewer CSS as text) |
| `live-activity` | A Live Activity or Lock Screen control is already up when the user acts | Feed the lifecycle events with the activity present; assert one owner of the audio session and that the controls still map to a live state | `SessionKit/LiveActivityLifecycle`, `LiveSessionTransportGuard` | #1337 (audio continues after idle; Live Activity cannot reopen controls), #2182 (phantom Now Playing ends the recording) |
| `hot` | Hot, Low Power Mode or short on memory | Inject the thermal, power and memory readings; assert what the governor slows or stops | `SessionKit/OnDeviceVoiceGovernor`, `OnDeviceCPUBudget`, `RenderHeadroomMemory`, `RenderAheadPolicy`, `MemoryFootprintLog` | #1681 (renders the whole article ahead on a hot phone), #1786 (voice bounces on a warm phone) |
| `burst` | Many requests at once, a double tap, work overlapping | Fire the request twice, or N at once, at the gate; assert one wins and the queue admits what it should | `SessionKit/LibraryAudioPreparationAdmission`, `RecordingSaveTapGuard`, `RunAgainGate` | #281 (many items prepare at once, none finishes), #1671 (two Margins play over each other) |
| `long-source` | A source far bigger than the test fixtures: a two-hour podcast, a long PDF | Generate the big input in the test (a fake spine of N thousand entries) and assert size limits and time | `SessionKit/EpisodeFingerprintSpineCompaction`, `BridgeManifest` | #2118 (manifest too large), #873 (app ended for memory on a two-hour podcast; also `hot`) |

A bug can meet two rows (`also` in the list); it counts once, under its main row.

## Bugs with no row

`none:<why>` marks 74 bugs. These are not device conditions, and most are host-testable already or are not tests at all: `logic` (35, a state machine or rule wrong on any phone), `visual` (24, layout, contrast, tap targets; the accessibility scans and screen checks cover them), `design` (5), `parse-fixture` (4, a page, feed or file shape; a fixture), `unclear` (4, the cause is unknown: #540, #937, #1696, #2856), `ears` (1) and `ops` (1).

## Missing seams

A condition the host cannot put the code in today. Two or more bugs needed each of these, so each has its own issue.

- **iOS's own kill and suspend, as the system meters it** (#3936). Host tests can check our budgets (`OnDeviceCPUBudget`) but not that iOS would kill the app: #1679, #2184, #2695.
- **Real route timing: Bluetooth, AirPlay and phantom Now Playing** (#3937). A fake route event proves our reaction, not that the microphone opens in under a second or that a phantom play arrives at all: #1506, #1668, #1708, #2182, #3633.

## Waste signal

Over the next 30 phone-found bugs, run `scripts/device_conditions.py --after-issue 3897 --first 30` (#3897 is the last bug listed). If device-condition and performance bugs (every row above) are still more than half, the table is not finding scenarios, and the spend moves to an agent walking the changed flow (#3899). Today: 70 of 144 (49%).
