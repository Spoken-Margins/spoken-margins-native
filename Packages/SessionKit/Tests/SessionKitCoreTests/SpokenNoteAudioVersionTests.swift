import XCTest
@testable import SessionKit

/// #4779: the listener's choice, the note's two clocks read from its files, where a version change starts, and the
/// words the control and Now say.
final class SpokenNoteAudioVersionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private let takeA = SpokenNoteWholeAudioLayout.Requested(id: "a", audioFileName: "take-a.m4a", durationMs: 4_000)

    /// A note of one 4 s take whose version keeps 0–1 s and 2.5–4 s: 2.5 s long.
    private func writeNote(cleanRequested: [SpokenNoteWholeAudioLayout.Requested]? = nil, withAudio: Bool = true) throws {
        let recorded = SpokenNoteWholeAudioLayout(requested: [takeA], placed: [.init(takeId: "a", startMs: 0, durationMs: 4_000)], durationMs: 4_000)
        try JSONEncoder().encode(recorded).write(to: folder.appendingPathComponent(SpokenNoteWholePlayback.layoutFileName))
        let clean = SpokenNoteCleanLayout(
            requested: cleanRequested ?? [takeA], cutFingerprints: ["a": "x"],
            placements: [
                .init(takeId: "a", takeStartMs: 0, takeEndMs: 1_000, outputStartMs: 0),
                .init(takeId: "a", takeStartMs: 2_500, takeEndMs: 4_000, outputStartMs: 1_000),
            ],
            durationMs: 2_500, result: .made(savedMs: 1_500)
        )
        try SpokenNoteCleanFiles.write(clean, to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: folder))
        if withAudio { try Data([0]).write(to: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder)) }
    }

    private var cleanURL: String { SpokenNoteCleanFiles.audioURL(inNoteFolder: folder).absoluteString }
    private var recordedURL: String { SpokenNoteWholePlayback.audioURL(inFolder: folder).absoluteString }

    // MARK: The choice

    func testTheChoiceIsAsRecordedUntilChangedAndIsKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "spoken-note-version-\(UUID().uuidString)"))
        XCTAssertEqual(SpokenNoteAudioVersion.stored(in: defaults), .asRecorded)
        SpokenNoteAudioVersion.shorterPauses.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "spokenNoteAudioVersion"), "shorter_pauses")
        XCTAssertEqual(SpokenNoteAudioVersion.stored(in: defaults), .shorterPauses)
        defaults.set("no_such_version", forKey: SpokenNoteAudioVersion.defaultsKey)
        XCTAssertEqual(SpokenNoteAudioVersion.stored(in: defaults), .asRecorded, "an unknown value falls back to As recorded")
    }

    // MARK: The clock

    func testTimesOnTheVersionAreSavedOnTheRecordingsClockAndBack() throws {
        try writeNote()
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: cleanURL), 3_000)
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 500, mediaURL: cleanURL), 500)
        XCTAssertEqual(SpokenNoteCleanClock.playingMs(recordedMs: 3_000, mediaURL: cleanURL), 1_500)
        XCTAssertEqual(SpokenNoteCleanClock.playingMs(recordedMs: 1_800, mediaURL: cleanURL), 1_000, "a time in a cut pause plays from the next kept moment")
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: cleanURL.replacingOccurrences(of: "file://", with: "")), 3_000, "a plain path too")
    }

    func testTheRecordingAndOtherMediaPassThroughUnchanged() throws {
        try writeNote()
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: recordedURL), 1_500)
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: "https://example.com/clean/episode.m4a"), 1_500)
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: nil), 1_500)
    }

    func testAVersionMadeFromOtherTakesOrWithNoFileHasNoMap() throws {
        let other = SpokenNoteWholeAudioLayout.Requested(id: "b", audioFileName: "take-b.m4a", durationMs: 4_000)
        try writeNote(cleanRequested: [takeA, other])
        XCTAssertNil(SpokenNoteCleanClock.map(forMediaURL: cleanURL), "a take was added since the version was made")
        try FileManager.default.removeItem(at: SpokenNoteCleanFiles.folder(inNoteFolder: folder))
        try writeNote(withAudio: false)
        XCTAssertNil(SpokenNoteCleanClock.map(forMediaURL: cleanURL))
    }

    func testTheMapIsReadAgainWhenTheVersionIsMadeAgain() throws {
        try writeNote(withAudio: false)
        XCTAssertNil(SpokenNoteCleanClock.map(forMediaURL: cleanURL))
        try Data([0]).write(to: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder))
        // The layout is written again with the audio, as the renderer does; the cache notices.
        let layout = try XCTUnwrap(SpokenNoteCleanFiles.readLayout(inNoteFolder: folder))
        try SpokenNoteCleanFiles.write(SpokenNoteCleanLayout(
            requested: layout.requested, cutFingerprints: ["a": "yy"], placements: layout.placements,
            durationMs: layout.durationMs, result: layout.result
        ), to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: folder))
        XCTAssertNotNil(SpokenNoteCleanClock.map(forMediaURL: cleanURL))
    }

    // MARK: A version change

    func testAChangeStartsAtTheSameMomentOfTheRecording() throws {
        try writeNote()
        XCTAssertEqual(SpokenNoteVersionSwitch.plan(previousMediaURL: recordedURL, newMediaURL: cleanURL)?.startMs(playingMs: 3_000), 1_500)
        XCTAssertEqual(SpokenNoteVersionSwitch.plan(previousMediaURL: cleanURL, newMediaURL: recordedURL)?.startMs(playingMs: 1_500), 3_000)
        XCTAssertNil(SpokenNoteVersionSwitch.plan(previousMediaURL: cleanURL, newMediaURL: cleanURL))
        XCTAssertNil(SpokenNoteVersionSwitch.plan(previousMediaURL: recordedURL, newMediaURL: recordedURL))
        XCTAssertEqual(SpokenNoteVersionSwitch.plan(previousMediaURL: nil, newMediaURL: cleanURL)?.startMs(playingMs: 0), 0)
    }

    func testThePlanHoldsBothClocksSoTheRestartReadsNoFile() throws {
        try writeNote()
        let plan = try XCTUnwrap(SpokenNoteVersionSwitch.plan(previousMediaURL: recordedURL, newMediaURL: cleanURL))
        // The main actor uses the plan after the read; the files may change by then, and it must not look at them again.
        try FileManager.default.removeItem(at: folder)
        XCTAssertEqual(plan.startMs(playingMs: 3_000), 1_500)
        XCTAssertEqual(plan.startMs(playingMs: 1_800), 1_000, "a place in a cut pause starts at the next kept moment")
        XCTAssertEqual(plan.previousMediaURL, recordedURL)
        XCTAssertEqual(plan.newMediaURL, cleanURL)
    }

    // MARK: Margins on the playing clock

    private func spokenMargin(_ id: String, savedMs: Int?) -> Interjection {
        Interjection(
            id: id, itemId: "note-item", sessionId: "session", targetType: .item, targetId: "note-item",
            createdAt: Date(timeIntervalSince1970: 0), roughPercent: 50,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: savedMs),
            audioPath: "\(id).m4a", audioStatus: "saved", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin", status: "active")
    }

    func testAMarginMomentOnShorterPausesSeeksToTheWordsNotTheRecordingsTime() throws {
        try writeNote()
        let played = spokenMargin("m1", savedMs: 3_000) // 3 s on the recording is 1.5 s on the version
        let later = spokenMargin("m2", savedMs: 3_500)
        let onClock = SpokenNoteCleanClock.onPlayingClock([played, later], mediaURL: cleanURL)
        let anchors = try XCTUnwrap(MarginMomentPlanner.anchors(
            played: onClock[0], among: onClock, clock: .media, targetMediaTimeMs: 1_500))
        XCTAssertEqual(anchors.target.mediaTimeMs, 1_500, "the saved time would land 1.5 s past the words")
        XCTAssertEqual(anchors.others.map(\.mediaTimeMs), [2_000])
        XCTAssertEqual(onClock[0].anchor.anchorType, .media, "only the time moves")
    }

    func testTheTimelinePlacesMarginsOnTheShorterFileWithTheMapItRead() throws {
        try writeNote()
        let margins = [spokenMargin("m1", savedMs: 3_000), spokenMargin("m2", savedMs: nil)]
        let map = try XCTUnwrap(SpokenNoteCleanClock.map(forMediaURL: cleanURL))
        let placed = SpokenNoteCleanClock.moved(margins, by: map)
        XCTAssertEqual(placed[0].anchor.mediaTimeMs, 1_500, "a row at the recording's 3 s sits past its words on the shorter file")
        XCTAssertNil(placed[1].anchor.mediaTimeMs)
        XCTAssertEqual(SpokenNoteCleanClock.moved(margins, by: nil), margins, "the recording plays: as saved")
    }

    func testMarginsStayAsSavedOnTheRecordingAndWithNoTime() throws {
        try writeNote()
        let margins = [spokenMargin("m1", savedMs: 3_000), spokenMargin("m2", savedMs: nil)]
        XCTAssertEqual(SpokenNoteCleanClock.onPlayingClock(margins, mediaURL: recordedURL), margins)
        XCTAssertEqual(SpokenNoteCleanClock.onPlayingClock(margins, mediaURL: nil), margins)
        XCTAssertEqual(SpokenNoteCleanClock.onPlayingClock(margins, mediaURL: "https://example.com/episode.mp3"), margins)
        XCTAssertNil(SpokenNoteCleanClock.onPlayingClock(margins, mediaURL: cleanURL)[1].anchor.mediaTimeMs, "a missing time is never made 0:00")
    }

    private func noteItem(attached url: String, mediaType: String = SpokenNoteItem.mediaType) -> Item {
        Item(
            id: "note", title: "A note", mediaType: mediaType, text: nil, externalReference: "note://n", status: "ready",
            externalReferenceType: SpokenNoteItem.referenceType,
            media: ItemMedia(sourceType: .nativeMediaFile, url: url, durationMs: 4_000, nativeMediaId: "note-audio"))
    }

    func testAWatchMarginKeepsItsWordsWhenTheNoteMovedToTheOtherVersionWhileItRecorded() throws {
        try writeNote()
        // Taken at 3 s on the recording; the version was attached before the Margin was written: 1.5 s on that file.
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(3_000, playedOn: recordedURL, item: noteItem(attached: cleanURL)), 1_500)
        // Taken at 1.5 s on the version; As recorded was chosen before it was written: 3 s on the recording.
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(1_500, playedOn: cleanURL, item: noteItem(attached: recordedURL)), 3_000)
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(1_500, playedOn: cleanURL, item: noteItem(attached: cleanURL)), 1_500, "same file")
        // #4779 audits on 9443c0a and 12a94f7: a Watch place with no file, on a note with a version, has no known clock,
        // so it is never guessed.
        XCTAssertThrowsError(try PlayerItemMargin.timeOnAttachedFile(1_500, playedOn: nil, item: noteItem(attached: cleanURL))) {
            XCTAssertEqual($0 as? PlayerItemMargin.Failure, .clockUnknown)
        }
        XCTAssertThrowsError(try PlayerItemMargin.timeOnAttachedFile(1_500, playedOn: nil, item: noteItem(attached: recordedURL)))
        // A run's place with no file was saved by a build before the version existed: the recording's clock.
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(3_000, playedOn: nil, fromRun: true, item: noteItem(attached: cleanURL)), 1_500)
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(3_000, playedOn: nil, fromRun: true, item: noteItem(attached: recordedURL)), 3_000)
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(
            1_500, playedOn: nil, item: noteItem(attached: recordedURL, mediaType: "podcast")), 1_500, "any other item keeps its time")
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(
            1_500, playedOn: cleanURL, item: noteItem(attached: recordedURL, mediaType: "podcast")), 1_500, "only a note has two clocks")
    }

    func testANotePlaceWithNoFileKeepsItsTimeWhenTheNoteHasNoVersion() throws {
        // #4779 audit on 12a94f7: with no version (every note of a listener on As recorded) there is one clock, so an
        // older Watch's place, or one whose record the phone lost, is still placed.
        try writeNote(withAudio: false)
        XCTAssertFalse(SpokenNoteCleanClock.hasVersion(noteMediaURL: recordedURL))
        XCTAssertEqual(try PlayerItemMargin.timeOnAttachedFile(3_000, playedOn: nil, item: noteItem(attached: recordedURL)), 3_000)
        try Data([0]).write(to: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder))
        XCTAssertTrue(SpokenNoteCleanClock.hasVersion(noteMediaURL: recordedURL), "read from the recording's URL")
        XCTAssertTrue(SpokenNoteCleanClock.hasVersion(noteMediaURL: cleanURL))
        XCTAssertTrue(SpokenNoteCleanClock.hasVersion(noteMediaURL: SpokenNoteWholePlayback.audioURL(inFolder: folder).path), "or its path")
        XCTAssertFalse(SpokenNoteCleanClock.hasVersion(noteMediaURL: nil))
    }

    func testOnlyAMarginRunningOnTheSessionHoldsAVersionChange() {
        XCTAssertFalse(SpokenNoteVersionPlan.phaseHoldsVersionChange(.finished), "a note played to its end leaves the choice open")
        XCTAssertFalse(SpokenNoteVersionPlan.phaseHoldsVersionChange(.itemPlayback))
        XCTAssertFalse(SpokenNoteVersionPlan.phaseHoldsVersionChange(.idle))
        XCTAssertFalse(SpokenNoteVersionPlan.phaseHoldsVersionChange(.abandoned))
        for phase: SessionPhase in [.recordingInterjection, .interjectionSummary, .summaryPlayback, .addendumCapture, .aiResponsePlayback, .conversation] {
            XCTAssertTrue(SpokenNoteVersionPlan.phaseHoldsVersionChange(phase), phase.rawValue)
        }
    }

    func testAMarginMomentNeverRunsOnAcrossAVersionChange() {
        XCTAssertEqual(SpokenNoteVersionPlan.marginMomentAction(isRunning: false, isPlayingVoice: false), .none)
        XCTAssertEqual(SpokenNoteVersionPlan.marginMomentAction(isRunning: true, isPlayingVoice: true), .hold,
                       "a Margin's voice playing holds the note where it is")
        XCTAssertEqual(SpokenNoteVersionPlan.marginMomentAction(isRunning: true, isPlayingVoice: false), .end,
                       "a moment listening on the old file's clock would play its Margins at the wrong words")
    }

    func testTheAttachedVersionIsReadFromTheURLAlone() {
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: cleanURL), .shorterPauses)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: recordedURL), .asRecorded)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: nil), .asRecorded)
    }

    // MARK: Words

    func testNumberRules() {
        XCTAssertEqual(SpokenNoteCleanWords.percent(0), 0)
        XCTAssertEqual(SpokenNoteCleanWords.percent(0.049), 0)
        XCTAssertEqual(SpokenNoteCleanWords.percent(0.123), 10)
        XCTAssertEqual(SpokenNoteCleanWords.percent(0.999), 95)
        XCTAssertEqual(SpokenNoteCleanWords.percent(1), 100)
        XCTAssertEqual(SpokenNoteCleanWords.percent(.nan), 0)
        XCTAssertEqual(SpokenNoteCleanWords.length(45_000), "45 s")
        XCTAssertEqual(SpokenNoteCleanWords.length(59_400), "59 s")
        XCTAssertEqual(SpokenNoteCleanWords.length(60_000), "1 min")
        XCTAssertEqual(SpokenNoteCleanWords.length(12 * 60_000 + 29_000), "12 min")
        XCTAssertEqual(SpokenNoteCleanWords.shorter(savedMs: 59_999), "under a minute shorter")
        XCTAssertEqual(SpokenNoteCleanWords.shorter(savedMs: 7 * 60_000 + 10_000), "7 min shorter")
    }

    func testTheControlAndNowSayTheSameThing() {
        XCTAssertEqual(SpokenNoteCleanWords.segment(.asRecorded), "As recorded")
        XCTAssertEqual(SpokenNoteCleanWords.segment(.shorterPauses), "Shorter pauses")
        XCTAssertNil(SpokenNoteCleanWords.nowLine(.asRecorded))
        XCTAssertNil(SpokenNoteCleanWords.nowLine(.untilPlayed))
        XCTAssertNil(SpokenNoteCleanWords.nowLine(.nothingToRemove))
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(.making(fraction: 0.42)), "Shortening pauses… 40%")
        XCTAssertEqual(SpokenNoteCleanWords.caption(.making(fraction: 0.42)).line, "Shortening long pauses… 40%. Playing as recorded until it's ready.")
        let ready = SpokenNoteCleanState.ready(recordedMs: 20 * 60_000, versionMs: 13 * 60_000)
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(ready), "Shorter pauses · 7 min shorter")
        XCTAssertEqual(SpokenNoteCleanWords.caption(ready).line, "Long pauses are shortened. Your recording stays as it is.")
        XCTAssertEqual(SpokenNoteCleanWords.caption(ready).second, "20 min as recorded, 13 min with shorter pauses.")
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(.hot), "As recorded for now")
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(.failed(.noSpace)), "As recorded for now")
        XCTAssertTrue(SpokenNoteCleanState.failed(.other).offersTryAgain)
        XCTAssertFalse(SpokenNoteCleanState.hot.offersTryAgain)
        for state: SpokenNoteCleanState in [.asRecorded, .untilPlayed, .making(fraction: 0.5), ready, .nothingToRemove, .hot, .failed(.noSpace), .failed(.other)] {
            XCTAssertFalse(SpokenNoteCleanWords.caption(state).line.lowercased().contains(" um"), "branch C promises nothing about ums: \(state)")
        }
    }

    func testTheSavedResultBecomesTheControlsState() {
        XCTAssertEqual(SpokenNoteCleanState.from(result: .made(savedMs: 5), recordedMs: 10, versionMs: 5), .ready(recordedMs: 10, versionMs: 5))
        XCTAssertEqual(SpokenNoteCleanState.from(result: .nothingToRemove, recordedMs: 10, versionMs: 0), .nothingToRemove)
        XCTAssertEqual(SpokenNoteCleanState.from(result: .failed(.noSpace), recordedMs: 10, versionMs: 0), .failed(.noSpace))
    }
}
