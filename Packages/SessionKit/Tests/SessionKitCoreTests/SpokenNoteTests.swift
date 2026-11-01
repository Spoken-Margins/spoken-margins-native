import Foundation
import XCTest
@testable import SessionKit

final class SpokenNoteTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func sentence(_ text: String, _ start: Int, _ end: Int) -> SpokenNoteSentence {
        SpokenNoteSentence(text: text, startMs: start, endMs: end)
    }

    private func take(_ id: String, durationMs: Int = 10_000, _ sentences: [SpokenNoteSentence] = []) -> SpokenNoteTake {
        SpokenNoteTake(id: id, audioFileName: "\(id).m4a", durationMs: durationMs, createdAt: date, sentences: sentences)
    }

    private func makeNote() -> SpokenNote {
        var note = SpokenNote(id: "note")
        note.appendTake(take("t1", [sentence("First idea.", 0, 3_000), sentence("Second idea.", 3_000, 7_000)]))
        note.appendTake(take("t2", durationMs: 5_000, [sentence("Back again.", 500, 4_000)]))
        return note
    }

    // MARK: takes append and never change

    func testAppendingATakeLeavesEarlierTakesAsTheyWereAndRefusesARepeatedId() {
        var note = makeNote()
        let before = note.takes
        XCTAssertTrue(note.appendTake(take("t3", [sentence("More.", 0, 1_000)])))
        XCTAssertEqual(Array(note.takes.prefix(2)), before)
        XCTAssertFalse(note.appendTake(take("t1", [sentence("Different.", 0, 1)])), "a save that runs twice can't double a take")
        XCTAssertEqual(note.takes.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(note.takes[0].sentences.first?.text, "First idea.")
    }

    func testANoteBuiltFromTakesDropsRepeatedIdsKeepingTheFirst() {
        let note = SpokenNote(id: "n", takes: [take("a", [sentence("one", 0, 1)]), take("b"), take("a", [sentence("two", 0, 1)])])
        XCTAssertEqual(note.takes.map(\.id), ["a", "b"])
        XCTAssertEqual(note.text, "one")
    }

    func testATranscriptThatArrivesLateIsFilledInOnceAndNeverReplaced() {
        var note = SpokenNote(id: "n", takes: [take("a")])
        XCTAssertFalse(note.takes[0].hasTranscript)
        XCTAssertFalse(note.setTranscript([], forTake: "a"), "an empty transcript is not a transcript")
        XCTAssertFalse(note.setTranscript([sentence("x", 0, 1)], forTake: "missing"))
        XCTAssertTrue(note.setTranscript([sentence("Hello there.", 0, 2_000)], forTake: "a"))
        XCTAssertFalse(note.setTranscript([sentence("Something else.", 0, 2_000)], forTake: "a"), "dictated text is never replaced")
        XCTAssertEqual(note.text, "Hello there.")
        XCTAssertEqual(note.takes[0].audioFileName, "a.m4a")
        XCTAssertEqual(note.takes[0].durationMs, 10_000)
    }

    func testTextIsEveryTakesSentencesInOrderAndEmptyTakesAddNothing() {
        var note = makeNote()
        note.appendTake(take("silent"))
        XCTAssertEqual(note.text, "First idea. Second idea. Back again.")
        XCTAssertEqual(SpokenNote(id: "n").text, "")
        XCTAssertTrue(SpokenNote(id: "n").isEmpty)
    }

    // MARK: sentence to audio

    func testTappingASentencePlaysItsSpanOfItsOwnTake() throws {
        let note = makeNote()
        let refs = note.sentenceRefs
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(note.playback(for: refs[1]), SpokenNotePlayback(takeId: "t1", audioFileName: "t1.m4a", startMs: 3_000, endMs: 7_000))
        XCTAssertEqual(note.playback(for: refs[2]), SpokenNotePlayback(takeId: "t2", audioFileName: "t2.m4a", startMs: 500, endMs: 4_000),
                       "the first sentence of a later take starts at its own time, not after the earlier take")
    }

    func testSentenceTimesPastTheAudioAreClampedOrHaveNothingToPlay() {
        var note = SpokenNote(id: "n")
        note.appendTake(take("t", durationMs: 5_000, [
            sentence("runs over", 4_000, 9_000), sentence("starts at the end", 5_000, 6_000), sentence("starts past it", 8_000, 9_000),
        ]))
        let refs = note.sentenceRefs
        XCTAssertEqual(note.playback(for: refs[0])?.endMs, 5_000, "clamped to the audio")
        XCTAssertNil(note.playback(for: refs[1]), "nothing is playable at or after the end")
        XCTAssertNil(note.playback(for: refs[2]))
        XCTAssertEqual(note.text, "runs over starts at the end starts past it", "the text stays whether or not audio backs it")
    }

    func testBadSentenceTimesAreMadeSane() {
        let s = SpokenNoteSentence(text: "x", startMs: -500, endMs: -900)
        XCTAssertEqual(s.startMs, 0)
        XCTAssertEqual(s.endMs, 0)
        XCTAssertEqual(SpokenNoteSentence(text: "x", startMs: 2_000, endMs: 1_000).endMs, 2_000)
        XCTAssertEqual(SpokenNoteTake(id: "a", audioFileName: "a", durationMs: -4, createdAt: date).durationMs, 0)
    }

    func testAnUnknownSentenceHasNoPlayback() {
        let note = makeNote()
        XCTAssertNil(note.playback(for: .init(takeIndex: 9, sentenceIndex: 0)))
        XCTAssertNil(note.playback(for: .init(takeIndex: 0, sentenceIndex: 9)))
        XCTAssertNil(note.playback(for: .init(takeIndex: -1, sentenceIndex: 0)))
        XCTAssertNil(note.sentence(.init(takeIndex: 0, sentenceIndex: -1)))
    }

    // MARK: audio position to sentence

    func testAPositionInAnTakeMapsToTheSentenceBeingSpoken() {
        let note = makeNote()
        XCTAssertEqual(note.sentence(inTake: "t1", atMs: 0), .init(takeIndex: 0, sentenceIndex: 0))
        XCTAssertEqual(note.sentence(inTake: "t1", atMs: 2_999), .init(takeIndex: 0, sentenceIndex: 0))
        XCTAssertEqual(note.sentence(inTake: "t1", atMs: 3_000), .init(takeIndex: 0, sentenceIndex: 1), "a sentence owns the time it starts at")
        XCTAssertEqual(note.sentence(inTake: "t1", atMs: 9_500), .init(takeIndex: 0, sentenceIndex: 1), "after the last sentence's end, it is still the last one")
        XCTAssertEqual(note.sentence(inTake: "t2", atMs: 600), .init(takeIndex: 1, sentenceIndex: 0))
    }

    func testPositionsBeforeTheFirstSentenceUnknownTakesAndEmptyTakesGiveNothing() {
        var note = makeNote()
        note.appendTake(take("silent"))
        XCTAssertNil(note.sentence(inTake: "t2", atMs: 100), "t2's first sentence starts at 500")
        XCTAssertNil(note.sentence(inTake: "nope", atMs: 0))
        XCTAssertNil(note.sentence(inTake: "silent", atMs: 0))
        XCTAssertNil(note.sentence(inTake: "t1", atMs: -1))
    }

    func testOverlappingSentencesResolveToTheOneThatStartedLast() {
        var note = SpokenNote(id: "n")
        note.appendTake(take("t", [sentence("a", 0, 5_000), sentence("b", 3_000, 6_000)]))
        XCTAssertEqual(note.sentence(inTake: "t", atMs: 4_000), .init(takeIndex: 0, sentenceIndex: 1))
        XCTAssertEqual(note.sentence(inTake: "t", atMs: 2_000), .init(takeIndex: 0, sentenceIndex: 0))
    }

    func testTheTwoMappingsAgreeForEverySentenceOfASimpleNote() throws {
        let note = makeNote()
        for ref in note.sentenceRefs {
            let play = try XCTUnwrap(note.playback(for: ref))
            XCTAssertEqual(note.sentence(inTake: play.takeId, atMs: play.startMs), ref)
        }
    }

    // MARK: the file

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpokenNoteTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testANoteSurvivesBeingSavedAndLoaded() throws {
        let store = SpokenNoteStore(folderURL: try tempFolder(), noteId: "note")
        let note = makeNote()
        try store.save(note)
        XCTAssertEqual(store.load(), note)
    }

    func testAMissingFileIsAnEmptyNote() throws {
        let store = SpokenNoteStore(folderURL: try tempFolder(), noteId: "fresh")
        XCTAssertEqual(store.load(), SpokenNote(id: "fresh"))
    }

    func testAnUnreadableFileIsSetAsideNotOverwrittenByTheNextSave() throws {
        let folder = try tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SpokenNoteStore(folderURL: folder, noteId: "note")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: store.fileURL)

        XCTAssertEqual(store.load(), SpokenNote(id: "note"), "the listener sees an empty note, not an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: store.setAsideURL), damaged)

        try store.save(makeNote())
        XCTAssertEqual(try Data(contentsOf: store.setAsideURL), damaged, "saving afterwards leaves the set-aside file alone")

        // A second unreadable file does not overwrite the first one set aside.
        let second = Data("also broken".utf8)
        try second.write(to: store.fileURL)
        _ = store.load()
        XCTAssertEqual(try Data(contentsOf: store.setAsideURL), damaged)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("note.unreadable.2.json")), second)
    }

    func testAFileFromANewerBuildIsSetAsideUntouched() throws {
        let folder = try tempFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SpokenNoteStore(folderURL: folder, noteId: "note")
        let future = Data(#"{"id":"note","schemaVersion":99,"takes":[]}"#.utf8)
        try future.write(to: store.fileURL)
        XCTAssertEqual(store.load(), SpokenNote(id: "note"))
        XCTAssertEqual(try Data(contentsOf: store.setAsideURL), future)
    }

    func testTheStoredShapeIsPlainJSONAnOlderReaderCanFollow() throws {
        let store = SpokenNoteStore(folderURL: try tempFolder(), noteId: "note")
        try store.save(makeNote())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let takes = try XCTUnwrap(json["takes"] as? [[String: Any]])
        XCTAssertEqual(takes.first?["audioFileName"] as? String, "t1.m4a")
        XCTAssertNotNil(takes.first?["createdAt"] as? String, "dates are ISO 8601 text")
    }
}
