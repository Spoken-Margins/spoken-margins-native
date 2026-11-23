import Foundation
import XCTest
@testable import SessionKit

/// Where a spoken note's export puts each Margin, and what words a Margin carries (#4782). One test per row of the
/// Design's table.
final class SpokenNoteExportLayoutTests: XCTestCase {
    private typealias F = SpokenNoteExportFixtures

    private func layout(
        _ margins: [Interjection],
        input: SpokenNoteExportInput? = F.input(),
        itemText: String = F.note().text,
        stored: TranscriptTimeline? = F.storedTimeline()
    ) -> SpokenNoteExportLayout {
        SpokenNoteExportLayout(input: input, itemId: F.itemId, itemText: itemText, storedTimeline: stored, margins: margins)
    }

    // 1
    func testASentenceIdPlacesTheMarginOnThatSentenceWhateverItsTime() throws {
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 8_500, segmentId: F.segmentId(F.takeA, 1))])
        let placement = try XCTUnwrap(result.placements["m"])
        XCTAssertEqual(placement.segmentId, "note-take-a-1-1")
        XCTAssertEqual(placement.startMs, 2_000, "the sentence's start on the joined clock")
        XCTAssertEqual(placement.startChar, 5)
        XCTAssertEqual(placement.sentence, "Two.")
        XCTAssertEqual(placement.nextSentence, "Three.")
        XCTAssertEqual(result.recordings[0].sentences[1].marginIds, ["m"])
    }

    // 2
    func testAnIdWhoseTakeWasRemovedFallsBackToTheTime() throws {
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 7_200, segmentId: "note-take-gone-0")])
        XCTAssertEqual(result.placements["m"]?.segmentId, F.segmentId(F.takeC, 0))
    }

    // 3
    func testATimeInThePauseBetweenTwoSentencesGoesToTheEarlierOne() {
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 1_500)])
        XCTAssertEqual(result.placements["m"]?.segmentId, F.segmentId(F.takeA, 0))
    }

    // 4
    func testAReadAloudMarginIsPlacedByItsCharacterOffsetIncludingOffsetZero() {
        let result = layout([
            F.margin("first", at: 1, startChar: 0),
            F.margin("later", at: 2, startChar: 19),
            F.margin("past", at: 3, startChar: 9_999),
        ])
        XCTAssertEqual(result.placements["first"]?.segmentId, F.segmentId(F.takeA, 0), "0 is a real offset")
        XCTAssertEqual(result.placements["later"]?.segmentId, F.segmentId(F.takeC, 0), "\"Four.\" holds characters 17 to 21")
        XCTAssertNil(result.placements["past"])
        XCTAssertEqual(result.unplacedMarginIds, ["past"])
    }

    // 5
    func testWithTheNoteFileButNoJoinedTimelineIdThenStoredTimeIsUsed() {
        let result = layout(
            [
                F.margin("by-id", at: 1, mediaTimeMs: 0, segmentId: F.segmentId(F.takeC, 1)),
                F.margin("by-time", at: 2, mediaTimeMs: 3_400),
            ],
            input: F.input(whole: nil)
        )
        XCTAssertEqual(result.placements["by-id"]?.segmentId, F.segmentId(F.takeC, 1))
        XCTAssertEqual(result.placements["by-time"]?.segmentId, F.segmentId(F.takeA, 2))
        XCTAssertNil(result.placements["by-id"]?.startMs, "with no joined layout there is no joined clock")
    }

    // 6
    func testAMarginWithNoPlaceSavedIsNeverPlacedEvenThoughItsTimeIsZero() {
        let result = layout([F.margin("m", at: 1, noPlace: true)])
        XCTAssertTrue(result.placements.isEmpty)
        XCTAssertEqual(result.unplacedMarginIds, ["m"])
    }

    // 7
    func testTwoMarginsOnOneSentenceGoInTheOrderTheyWereMade() {
        let result = layout([
            F.margin("made-second", at: 2, mediaTimeMs: 2_100),
            F.margin("made-first", at: 1, mediaTimeMs: 2_900),
        ])
        XCTAssertEqual(result.recordings[0].sentences[1].marginIds, ["made-first", "made-second"])
        XCTAssertEqual(result.margins.map(\.id), ["made-first", "made-second"])
    }

    // 8
    func testAWordlessRecordingInTheMiddleIsCountedAndKept() {
        let result = layout([])
        XCTAssertEqual(result.recordings.map(\.number), [1, 2, 3])
        XCTAssertEqual(result.recordings.map(\.hasWords), [true, false, true])
        XCTAssertEqual(result.recordingCount, 3)
        XCTAssertEqual(result.recordingsWithWords, 2)
        XCTAssertFalse(result.isComplete)
    }

    // 9
    func testANoteWithNoRecordingsHasNoWordsAndIsNotComplete() {
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 0)], input: F.input(note: F.note([]), whole: nil), stored: nil)
        XCTAssertTrue(result.recordings.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.hasAnyWords)
        XCTAssertEqual(result.unplacedMarginIds, ["m"])
    }

    // 10
    func testTheFallbackIsBuiltFromTheStoredTimelineWithTheRowsTail() throws {
        let result = layout(
            [F.margin("m", at: 1, segmentId: F.segmentId(F.takeC, 0))],
            input: nil, itemText: F.note().text + " Six, added during the join."
        )
        XCTAssertEqual(result.source, .lastPlayback)
        XCTAssertEqual(result.recordings.count, 1)
        let sentences = result.recordings[0].sentences
        XCTAssertEqual(sentences.map(\.text), ["One.", "Two.", "Three.", "Four.", "Five.", "Six, added during the join."])
        XCTAssertNil(sentences.last?.segmentId, "text past the timeline has no segment")
        XCTAssertEqual(result.placements["m"]?.sentence, "Four.")
        XCTAssertEqual(result.placements["m"]?.startMs, 7_000)
    }

    func testTheFallbackWithNoTimelineIsOneBlockAndPlacesNothing() {
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 2_000)], input: nil, itemText: "Only words.", stored: nil)
        XCTAssertEqual(result.recordings.first?.sentences.map(\.text), ["Only words."])
        XCTAssertEqual(result.unplacedMarginIds, ["m"])
    }

    func testTheFallbackWithNoWordsHasOneWordlessRecording() {
        let result = layout([], input: nil, itemText: "", stored: nil)
        XCTAssertEqual(result.recordings.count, 1)
        XCTAssertFalse(result.recordings[0].hasWords)
    }

    // 11
    func testATakeAddedAfterTheMarginsAppearsWithNoMarginsAndOldMarginsStay() {
        let takeD = SpokenNoteTake(id: "take-d", audioFileName: "take-d.m4a", durationMs: 1_000, createdAt: Date(timeIntervalSince1970: 40),
                                   sentences: [SpokenNoteSentence(text: "Six.", startMs: 0, endMs: 900)])
        let note = F.note([F.takeA, F.takeB, F.takeC, takeD])
        // The joined layout predates take-d.
        let whole = SpokenNoteWholeTimeline(note: note, layout: F.layout())
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 8_100, segmentId: F.segmentId(F.takeC, 1))],
                            input: F.input(note: note, whole: whole))
        XCTAssertEqual(result.recordings.count, 4)
        XCTAssertEqual(result.recordings[3].sentences.map(\.text), ["Six."])
        XCTAssertNil(result.recordings[3].sentences[0].startMs)
        XCTAssertEqual(result.placements["m"]?.segmentId, F.segmentId(F.takeC, 1))
        XCTAssertEqual(result.placements["m"]?.nextSentence, "", "the last sentence of its recording has nothing after it")
    }

    // 12
    func testATakeIdWithHyphensIsMatchedWholeNeverParsed() {
        let result = layout([F.margin("m", at: 1, segmentId: "note-take-a-1-2")], input: F.input(whole: nil))
        XCTAssertEqual(result.placements["m"]?.sentence, "Three.")
    }

    // 13
    func testASentenceOfTwoThousandCharactersIsCappedAtFiveHundred() {
        let long = String(repeating: "word ", count: 400)
        let take = SpokenNoteTake(id: "t", audioFileName: "t.m4a", durationMs: 5_000, createdAt: Date(),
                                  sentences: [SpokenNoteSentence(text: long, startMs: 0, endMs: 4_000),
                                              SpokenNoteSentence(text: long, startMs: 4_000, endMs: 5_000)])
        let result = layout([F.margin("m", at: 1, mediaTimeMs: 10)], input: F.input(note: F.note([take]), whole: F.whole([take])))
        XCTAssertEqual(result.placements["m"]?.sentence.count, 500)
        XCTAssertEqual(result.placements["m"]?.nextSentence.count, 500)
        XCTAssertEqual(result.recordings[0].sentences[0].text.count, 2_000, "the transcript itself is never cut")
    }

    // 14
    func testUnicodeAndWhitespaceOnlySentencesKeepTheirOffsetsInCharacters() {
        let take = SpokenNoteTake(id: "u", audioFileName: "u.m4a", durationMs: 5_000, createdAt: Date(),
                                  sentences: [SpokenNoteSentence(text: "Café 👩🏽‍💻.", startMs: 0, endMs: 1_000),
                                              SpokenNoteSentence(text: "   ", startMs: 1_000, endMs: 2_000),
                                              SpokenNoteSentence(text: "Ñandú.", startMs: 2_000, endMs: 3_000)])
        let note = F.note([take])
        let result = layout([F.margin("m", at: 1, startChar: 14)], input: F.input(note: note, whole: F.whole([take])))
        XCTAssertEqual(result.recordings[0].sentences.map(\.startChar), [0, 8, 12])
        XCTAssertEqual(result.text, note.text)
        XCTAssertEqual(result.placements["m"]?.sentence, "Ñandú.")
    }

    // 15
    func testAStoredSourceWindowIsNeverTheContext() {
        let window = String(repeating: "ninety seconds of words ", count: 50)
        let result = layout([
            F.margin("spoken", at: 1, mediaTimeMs: 2_500, anchorBefore: window, anchorAfter: window),
            F.margin("written", at: 2, mediaTimeMs: 7_100, written: true, anchorBefore: window, anchorAfter: window),
        ])
        XCTAssertEqual(result.placements["spoken"]?.sentence, "Two.")
        XCTAssertEqual(result.placements["spoken"]?.nextSentence, "Three.")
        XCTAssertEqual(result.placements["written"]?.sentence, "Four.")
        XCTAssertEqual(result.placements["written"]?.nextSentence, "Five.")
    }

    // 16
    func testALongNotePlacesEveryMarginOnceAndKeepsEverySentence() {
        let takes = (0..<3).map { takeIndex in
            SpokenNoteTake(
                id: "long-\(takeIndex)", audioFileName: "long-\(takeIndex).m4a", durationMs: 2_400_000, createdAt: Date(),
                sentences: (0..<1_000).map { SpokenNoteSentence(text: "Sentence \(takeIndex)-\($0).", startMs: $0 * 2_400, endMs: $0 * 2_400 + 2_000) }
            )
        }
        let whole = F.whole(takes)
        let margins = (0..<200).map { F.margin("m\($0)", at: Double($0), mediaTimeMs: $0 * 36_000) }
        let result = layout(margins, input: F.input(note: F.note(takes), whole: whole), stored: whole.mediaTimeline)
        XCTAssertEqual(result.recordings.flatMap(\.sentences).count, 3_000)
        XCTAssertEqual(result.placements.count, 200)
        XCTAssertEqual(result.recordings.flatMap(\.sentences).flatMap(\.marginIds).count, 200)
        XCTAssertTrue(result.unplacedMarginIds.isEmpty)
    }

    func testOnlyActiveMarginsOnTheNoteItselfAreLaidOut() {
        var deleted = F.margin("deleted", at: 1, mediaTimeMs: 0)
        deleted.status = "deleted"
        let onTurn = F.margin("turn", at: 2, mediaTimeMs: 0, targetType: .assistantTurn, targetId: "turn-1")
        let result = layout([deleted, onTurn, F.margin("kept", at: 3, mediaTimeMs: 0)])
        XCTAssertEqual(result.margins.map(\.id), ["kept"])
    }
}

final class SpokenNoteExportInputLoadTests: XCTestCase {
    func testTheLoaderReadsTheNotesOwnFileAndNothingForOtherItems() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("note-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let note = SpokenNoteExportFixtures.note()
        try XCTUnwrap(SpokenNoteStarter.store(noteId: note.id, in: support)).save(note)
        let loader = SpokenNoteExportInput.loader(applicationSupport: support)

        let loaded = try XCTUnwrap(loader(SpokenNoteExportFixtures.item()))
        XCTAssertEqual(loaded.note, note)
        XCTAssertNil(loaded.wholeTimeline, "never joined: no whole-note file")

        let article = Item(id: "a", title: "A", mediaType: "article", text: "x", externalReference: "note://n-1", status: "ready")
        XCTAssertNil(loader(article))
        XCTAssertNil(SpokenNoteExportInput.loader(applicationSupport: nil)(SpokenNoteExportFixtures.item()))
    }
}

final class ExportSourceKindTests: XCTestCase {
    func testANoteIsASpokenNoteBeforeAndAfterItFirstPlays() {
        let note = SpokenNoteExportFixtures.note()
        var item = SpokenNoteItem.makeItem(note: note, createdAt: Date())
        XCTAssertEqual(ExportSourceKind.of(item), .spokenNote)
        item.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///x.m4a", durationMs: 1)
        XCTAssertEqual(ExportSourceKind.of(item), .spokenNote, "attachPlayback makes it native audio to the player")
    }

    func testPodcastsAudioFilesArticlesPDFsAndTypedNotesAreNot() {
        func item(_ mediaType: String, _ source: AudioSourceType?) -> Item {
            Item(id: "i", title: "t", mediaType: mediaType, text: "x", externalReference: nil, status: "ready",
                 media: source.map { ItemMedia(sourceType: $0, url: "https://example.com/a", durationMs: 1) })
        }
        XCTAssertEqual(ExportSourceKind.of(item(TargetType.transcriptBackedMedia.rawValue, .remoteStream)), .nativeAudio)
        XCTAssertEqual(ExportSourceKind.of(item("audio_file", .nativeMediaFile)), .nativeAudio)
        XCTAssertEqual(ExportSourceKind.of(item("article", nil)), .text)
        XCTAssertEqual(ExportSourceKind.of(item("pdf", nil)), .text)
        XCTAssertEqual(ExportSourceKind.of(item("text", nil)), .text)
        XCTAssertEqual(ExportSourceKind.of(item("SPOKEN_NOTE", nil)), .spokenNote, "case does not matter, as with other media types")
    }
}
