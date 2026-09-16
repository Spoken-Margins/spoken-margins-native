# Remote podcast chapter startup recovery

Owner report: Lex Fridman #292, Robin Hanson, selecting Grabby aliens (3%) from Item Detail opens Playback, loads and fails. Closing the playback pill and trying again succeeds according to the owner.

Base: `6432044bdc5ebff4691a69bee2699c309222ebac`, `codex/provisional-next`, plus this uncommitted repair. No install or distribution performed.

Evidence: supplied recording DB681226-165D-416A-8B45-E3CB89113D42 shows starting at 21:26:55.948Z, failed at 21:27:06.513Z, another start at 21:27:07.781Z and failure at 21:27:18.220Z. It ends during another start, before reported success. The engine has a ten-second startup deadline. The export omits the actual player error; network buffering versus seek failure is unresolved. A HEAD request on September 14 followed the supplied Blubrry redirect to HTTP 200 audio/mpeg, 189587385 bytes, with byte ranges advertised. This establishes current reachability only, not device playback success.

Implemented: on remote HTTP(S) item startup failure or deadline, stop and recreate transport once per explicit playback attempt, replaying the canonical requested position and rate. Retain position protection until confirmed. A second failure terminates the attempt. Local playback URLs and other target types keep existing behavior; explicit pause exits startup and cannot trigger recovery. No source identity, timeline, Library or anchor changes.

Verification: seven focused SessionKitCoreTests passed, zero failures, including four recovery combinations (initial error/timeout × retry success/timeout), chapter and media-time preservation despite a stale zero observation, bounded retries, local URL exclusion, paused-start exclusion, and existing startup/explicit-restart behavior. See focused-tests.log. git diff --check passed. New fixtures use synthetic chapter times, not a claimed exact publisher timestamp. Full app/release suites remain deferred under the current lane.

Command:
```sh
swift test --package-path Packages/SessionKit --filter 'SessionKitCoreTests.testRemoteChapterStartup|SessionKitCoreTests.testRemoteStartupRecovery|SessionKitCoreTests.testPlaybackStart|SessionKitCoreTests.testSameTargetPlaybackRestart'
```

Status: implemented and verified at the engine boundary. Physical AVPlayer/network recovery for this episode is not human_validated. The change closes the demonstrated missing recovery path; it does not establish or repair the unidentified original network/player cause. Owner recheck on a future installed candidate: start Grabby aliens from Item Detail while another episode occupies the pill; confirm audio starts at the chapter without closing the pill. Also pause during loading and confirm no later automatic start. No new human-validation handoff or install is requested here.
