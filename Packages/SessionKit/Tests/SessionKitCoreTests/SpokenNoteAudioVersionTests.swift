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
        defaults.set("without_ums", forKey: SpokenNoteAudioVersion.defaultsKey)
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
        XCTAssertEqual(SpokenNoteVersionPlan.switchStartMs(playingMs: 3_000, previousMediaURL: recordedURL, newMediaURL: cleanURL), 1_500)
        XCTAssertEqual(SpokenNoteVersionPlan.switchStartMs(playingMs: 1_500, previousMediaURL: cleanURL, newMediaURL: recordedURL), 3_000)
        XCTAssertNil(SpokenNoteVersionPlan.switchStartMs(playingMs: 1_500, previousMediaURL: cleanURL, newMediaURL: cleanURL))
        XCTAssertNil(SpokenNoteVersionPlan.switchStartMs(playingMs: 1_500, previousMediaURL: recordedURL, newMediaURL: recordedURL))
        XCTAssertEqual(SpokenNoteVersionPlan.switchStartMs(playingMs: 0, previousMediaURL: nil, newMediaURL: cleanURL), 0)
    }

    func testAStartFromElsewhereAttachesTheChosenVersionOnlyWhenItCanPlay() throws {
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: cleanURL), .shorterPauses)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: recordedURL), .asRecorded)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: nil), .asRecorded)
        XCTAssertFalse(SpokenNoteVersionPlan.startNeedsAttach(chosen: .shorterPauses, mediaURL: recordedURL, noteFolder: folder), "no version made yet")
        try writeNote()
        XCTAssertTrue(SpokenNoteVersionPlan.startNeedsAttach(chosen: .shorterPauses, mediaURL: recordedURL, noteFolder: folder))
        XCTAssertFalse(SpokenNoteVersionPlan.startNeedsAttach(chosen: .shorterPauses, mediaURL: cleanURL, noteFolder: folder))
        XCTAssertTrue(SpokenNoteVersionPlan.startNeedsAttach(chosen: .asRecorded, mediaURL: cleanURL, noteFolder: folder))
        XCTAssertFalse(SpokenNoteVersionPlan.startNeedsAttach(chosen: .asRecorded, mediaURL: recordedURL, noteFolder: folder))
        try FileManager.default.removeItem(at: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder))
        XCTAssertFalse(SpokenNoteVersionPlan.startNeedsAttach(chosen: .shorterPauses, mediaURL: recordedURL, noteFolder: folder), "the version's file is gone")
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
