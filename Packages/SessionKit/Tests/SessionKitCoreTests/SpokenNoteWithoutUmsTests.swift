import XCTest
@testable import SessionKit

/// #5342: a spoken note's Without ums version, made with the filler-word cleanup a shared Margin's Without ums voice
/// uses (`DeterministicInterjectionCleanup`), in its own folder and on its own clock.
final class SpokenNoteWithoutUmsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-ums-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func segment(_ index: Int, _ text: String, _ start: Int, _ end: Int) -> AlignedTranscriptSegment {
        AlignedTranscriptSegment(id: "seg-\(index)", text: text, startMs: start, endMs: end)
    }

    /// Quiet everywhere except the given spans, one flag per 20 ms.
    private func flags(durationMs: Int, loud: [Range<Int>]) -> [Bool] {
        (0..<(durationMs / 20)).map { index in
            let window = (index * 20)..<(index * 20 + 20)
            return !loud.contains { $0.overlaps(window) }
        }
    }

    private func placements(takeId: String, _ cut: SpokenNoteTakeCut) -> [SpokenNoteCleanPlacement] {
        var output = 0
        return cut.kept.map { span in
            defer { output += span.lengthMs }
            return SpokenNoteCleanPlacement(takeId: takeId, takeStartMs: span.startMs, takeEndMs: span.endMs, outputStartMs: output)
        }
    }

    /// "So um the result" then a 2 s pause, then "was": a filler and a long pause, in one 5 s take.
    private var take: [AlignedTranscriptSegment] {
        [segment(1, "So", 0, 800), segment(2, "um", 1_000, 1_300), segment(3, "the", 1_500, 1_800),
         segment(4, "result", 1_800, 2_400), segment(5, "was.", 4_400, 5_000)]
    }

    private var takeFlags: [Bool] { flags(durationMs: 5_000, loud: take.map { $0.startMs..<$0.endMs }) }

    // MARK: The cut

    func testTheFillerIsCutAsTheMarginsCleanupCutsItAndTheMarginLandsOnTheSameWord() throws {
        let cut = SpokenNoteTakeCut.make(withoutUms: take, silentFlags: takeFlags, durationMs: 5_000)

        // The Margins cleanup's own span for the um, padding included: this is the same detection, not a copy of it.
        let margins = DeterministicInterjectionCleanup.propose(AlignedInterjectionTranscript(text: "So um the result was.", segments: take))
        let umSpan = try XCTUnwrap(margins.decisions.first { $0.kind == .filler })
        XCTAssertEqual(umSpan.startMs..<umSpan.endMs, 960..<1_340)

        // The um is gone, and the 2 s pause keeps 500 ms as Shorter pauses keeps it.
        XCTAssertEqual(cut.kept, [.init(startMs: 0, endMs: 960), .init(startMs: 1_340, endMs: 2_650), .init(startMs: 4_150, endMs: 5_000)])
        XCTAssertEqual(cut.fillersRemoved, 1)
        XCTAssertEqual(cut.pausesShortened, 1)
        XCTAssertLessThan(cut.keptMs, SpokenNoteTakeCut.make(words: [], silentFlags: takeFlags, durationMs: 5_000).keptMs,
                          "shorter than the Shorter pauses version of the same take")

        // A Margin saved on "result" (1.8 s of the recording) plays on "result" in the shorter file, and back.
        let layout = SpokenNoteWholeAudioLayout(
            requested: [.init(id: "t", audioFileName: "take-t.m4a", durationMs: 5_000)],
            placed: [.init(takeId: "t", startMs: 0, durationMs: 5_000)], durationMs: 5_000)
        let map = SpokenNoteCleanMap(placements: placements(takeId: "t", cut), recorded: layout, cleanDurationMs: cut.keptMs)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 1_800), 960 + 460)
        XCTAssertEqual(map.recordedMs(fromCleanMs: 1_420), 1_800)
        XCTAssertEqual(map.cleanMs(fromRecordedMs: 4_400), 960 + 1_310 + 250, "\"was\" after the shortened pause")
    }

    func testIsolatedYouKnowGoesAndYouKnowWhatStaysAsInTheMarginsCleanup() {
        let alone = [segment(1, "It", 0, 200), segment(2, "was,", 200, 400), segment(3, "you", 400, 550),
                     segment(4, "know,", 550, 700), segment(5, "fine.", 700, 900)]
        let aloneCut = SpokenNoteTakeCut.make(withoutUms: alone, silentFlags: flags(durationMs: 1_000, loud: [0..<900]), durationMs: 1_000)
        XCTAssertEqual(aloneCut.fillersRemoved, 1)
        XCTAssertEqual(aloneCut.kept, [.init(startMs: 0, endMs: 400), .init(startMs: 700, endMs: 1_000)])

        let what = [segment(1, "And", 0, 200), segment(2, "you", 220, 320), segment(3, "know", 320, 470),
                    segment(4, "what", 470, 700), segment(5, "happened.", 700, 900)]
        let whatCut = SpokenNoteTakeCut.make(withoutUms: what, silentFlags: flags(durationMs: 1_000, loud: [0..<900]), durationMs: 1_000)
        XCTAssertEqual(whatCut.fillersRemoved, 0)
        XCTAssertTrue(whatCut.removesNothing)
    }

    func testNoUmWrittenDownLeavesOnlyThePausesAndAllUmsLeavesTheTakeAlone() {
        let plain = [segment(1, "Hello", 0, 800), segment(2, "there.", 3_000, 4_000)]
        let plainFlags = flags(durationMs: 4_000, loud: [0..<800, 3_000..<4_000])
        XCTAssertEqual(SpokenNoteTakeCut.make(withoutUms: plain, silentFlags: plainFlags, durationMs: 4_000),
                       SpokenNoteTakeCut.make(words: [], silentFlags: plainFlags, durationMs: 4_000),
                       "with no filler the version is the Shorter pauses one")

        // The Margins cleanup removes nothing from a Margin that is all fillers; the note keeps the same rule.
        let onlyUms = [segment(1, "Um", 0, 300), segment(2, "uh", 400, 700)]
        let onlyCut = SpokenNoteTakeCut.make(withoutUms: onlyUms, silentFlags: flags(durationMs: 800, loud: [0..<700]), durationMs: 800)
        XCTAssertEqual(onlyCut.fillersRemoved, 0)
        XCTAssertTrue(onlyCut.removesNothing)

        XCTAssertEqual(SpokenNoteTakeCut.make(withoutUms: [], silentFlags: [], durationMs: 0).kept, [])
    }

    // MARK: Files and clocks

    private let takeA = SpokenNoteWholeAudioLayout.Requested(id: "a", audioFileName: "take-a.m4a", durationMs: 4_000)

    /// One 4 s take. Shorter pauses keeps 0–1 s and 2.5–4 s; Without ums keeps 0–1 s and 3–4 s.
    private func writeNote() throws {
        let recorded = SpokenNoteWholeAudioLayout(requested: [takeA], placed: [.init(takeId: "a", startMs: 0, durationMs: 4_000)], durationMs: 4_000)
        try JSONEncoder().encode(recorded).write(to: folder.appendingPathComponent(SpokenNoteWholePlayback.layoutFileName))
        for (version, secondStart) in [(SpokenNoteAudioVersion.shorterPauses, 2_500), (.withoutUms, 3_000)] {
            let clean = SpokenNoteCleanLayout(
                requested: [takeA], cutFingerprints: ["a": version.rawValue],
                placements: [
                    .init(takeId: "a", takeStartMs: 0, takeEndMs: 1_000, outputStartMs: 0),
                    .init(takeId: "a", takeStartMs: secondStart, takeEndMs: 4_000, outputStartMs: 1_000),
                ],
                durationMs: 1_000 + 4_000 - secondStart, result: .made(savedMs: secondStart - 1_000)
            )
            try SpokenNoteCleanFiles.write(clean, to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: folder, version: version))
            try Data([0]).write(to: SpokenNoteCleanFiles.audioURL(inNoteFolder: folder, version: version))
        }
    }

    private func url(_ version: SpokenNoteAudioVersion) -> String {
        version == .asRecorded
            ? SpokenNoteWholePlayback.audioURL(inFolder: folder).absoluteString
            : SpokenNoteCleanFiles.audioURL(inNoteFolder: folder, version: version).absoluteString
    }

    func testWithoutUmsHasItsOwnFolderAndClock() throws {
        try writeNote()
        XCTAssertTrue(url(.withoutUms).hasSuffix("/clean-without-ums/whole-note.m4a"))
        XCTAssertTrue(url(.shorterPauses).hasSuffix("/clean/whole-note.m4a"), "Shorter pauses stays where it was")
        XCTAssertEqual(SpokenNoteCleanClock.playingMs(recordedMs: 3_500, mediaURL: url(.withoutUms)), 1_500)
        XCTAssertEqual(SpokenNoteCleanClock.playingMs(recordedMs: 3_500, mediaURL: url(.shorterPauses)), 2_000)
        XCTAssertEqual(SpokenNoteCleanClock.recordedMs(playingMs: 1_500, mediaURL: url(.withoutUms)), 3_500)
        XCTAssertTrue(SpokenNoteCleanClock.hasVersion(noteMediaURL: url(.asRecorded)))
    }

    func testANoteWithOnlyAWithoutUmsVersionStillHasAVersion() throws {
        try writeNote()
        try FileManager.default.removeItem(at: SpokenNoteCleanFiles.folder(inNoteFolder: folder, version: .shorterPauses))
        XCTAssertTrue(SpokenNoteCleanClock.hasVersion(noteMediaURL: url(.asRecorded)),
                      "a place with no file kept could be on the Without ums clock")
        XCTAssertNil(SpokenNoteCleanClock.map(forMediaURL: url(.shorterPauses)))
        XCTAssertNotNil(SpokenNoteCleanClock.map(forMediaURL: url(.withoutUms)))
    }

    func testMovingBetweenTheTwoMadeVersionsStartsAtTheSameMomentOfTheRecording() throws {
        try writeNote()
        // 2 s into Shorter pauses is 3.5 s of the recording, which is 1.5 s into Without ums.
        XCTAssertEqual(SpokenNoteVersionSwitch.plan(previousMediaURL: url(.shorterPauses), newMediaURL: url(.withoutUms))?.startMs(playingMs: 2_000), 1_500)
        XCTAssertEqual(SpokenNoteVersionSwitch.plan(previousMediaURL: url(.withoutUms), newMediaURL: url(.asRecorded))?.startMs(playingMs: 1_500), 3_500)
        XCTAssertNil(SpokenNoteVersionSwitch.plan(previousMediaURL: url(.withoutUms), newMediaURL: url(.withoutUms)))
    }

    func testTheAttachedVersionIsReadFromTheURLAndLookalikesAreNotVersions() {
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: url(.withoutUms)), .withoutUms)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: url(.shorterPauses)), .shorterPauses)
        XCTAssertEqual(SpokenNoteVersionPlan.attachedVersion(mediaURL: url(.asRecorded)), .asRecorded)
        for lookalike in ["/n/clean-without-ums-old/whole-note.m4a", "/n/Clean-Without-Ums/whole-note.m4a",
                          "/n/clean-without-ums/whole-note.json", "/n/clean-without-ums/", "clean-without-ums", ""] {
            XCTAssertNil(SpokenNoteCleanFiles.madeVersion(namedBy: lookalike), lookalike)
        }
        XCTAssertEqual(SpokenNoteCleanFiles.madeVersion(namedBy: "/n/clean-without-ums/whole-note.m4a"), .withoutUms, "a plain path too")
    }

    // MARK: The choice and its words

    func testTheChoiceIsKeptAndIsNeverOnUntilPicked() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "spoken-note-ums-\(UUID().uuidString)"))
        XCTAssertEqual(SpokenNoteAudioVersion.stored(in: defaults), .asRecorded)
        SpokenNoteAudioVersion.withoutUms.store(in: defaults)
        XCTAssertEqual(defaults.string(forKey: SpokenNoteAudioVersion.defaultsKey), "without_ums")
        XCTAssertEqual(SpokenNoteAudioVersion.stored(in: defaults), .withoutUms)
        XCTAssertEqual(SpokenNoteAudioVersion.allCases, [.asRecorded, .shorterPauses, .withoutUms], "the control's order")
    }

    func testTheControlUsesTheMarginsWording() {
        XCTAssertEqual(SpokenNoteCleanWords.segment(.withoutUms), ShareCleanupWords.withoutUms)
        XCTAssertEqual(SpokenNoteCleanWords.segment(.withoutUms), "Without ums")
        let ready = SpokenNoteCleanState.ready(recordedMs: 20 * 60_000, versionMs: 13 * 60_000)
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(ready, version: .withoutUms), "Without ums · 7 min shorter")
        XCTAssertEqual(SpokenNoteCleanWords.caption(ready, version: .withoutUms).second, "20 min as recorded, 13 min without ums.")
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(.making(fraction: 0.42), version: .withoutUms), "Removing ums… 40%")
        XCTAssertEqual(SpokenNoteCleanWords.nowLine(.failed(.other), version: .withoutUms), "As recorded for now")
        XCTAssertNil(SpokenNoteCleanWords.nowLine(.nothingToRemove, version: .withoutUms))
        XCTAssertTrue(SpokenNoteCleanWords.caption(.nothingToRemove, version: .withoutUms).line.hasSuffix("so it plays as recorded."))
        XCTAssertTrue(SpokenNoteCleanWords.caption(.failed(.other), version: .withoutUms).line.contains("plays as recorded"))
        XCTAssertEqual(SpokenNoteCleanWords.caption(.asRecorded, version: .withoutUms).line, SpokenNoteCleanWords.caption(.asRecorded).line)
    }
}
