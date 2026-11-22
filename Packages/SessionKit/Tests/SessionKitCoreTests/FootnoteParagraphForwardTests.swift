import Foundation
import XCTest
@testable import SessionKit

/// #3777, Design flow 3: while a note is read where it is cited, the paragraph-forward button (¶›) ends the note and
/// goes on with the next sentence of the main text. The player's held position is the citing sentence's end, so the
/// old rule (the next boundary from it) skipped the sentence after the note.
final class FootnoteParagraphForwardTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "timeline": ["chapter_timing"]
        ]
    )

    /// Two paragraphs. The citing sentence is the first one, so the held position during its note is `citingEnd`.
    private let text = "It cites a note. The next sentence follows it.\nA second paragraph starts here. It ends."
    private var citingEnd: Int { "It cites a note. ".count }
    private var secondParagraph: Int { "It cites a note. The next sentence follows it.\n".count }

    /// Reports where it was last asked to play from, and, while `continuation` is set, says a note is being read.
    private final class NoteAudio: AudioPlaybackClient {
        var charOffset: Int?
        var continuation: Int?
        var plays: [Int] = []
        var stops = 0

        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
        func play(targetId: String, from charOffset: Int) throws {
            self.charOffset = charOffset
            plays.append(charOffset)
        }
        func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
        func currentPlaybackPosition() -> PlaybackPosition? {
            charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }
        func currentCharOffset() -> Int? { charOffset }
        func currentMediaTimeMs() -> Int? { nil }
        func footnoteContinuationSourceOffset() -> Int? { continuation }
        func pause() throws {}
        func stop() throws { stops += 1 }
    }

    private var item: Item {
        Item(id: "item-notes", title: "Notes", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    /// The characters a Listening Map's spoken preface puts ahead of the text in what the player speaks.
    private var prefaceLength: Int { ItemPlaybackText.preface(item: item, map: mapItem, listenable: nil).count }
    private var mapItem: ListeningMap {
        ListeningMap(id: "map-notes", itemId: item.id, overview: "A short piece about notes.", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: text.count, percent: 0)
        ])
    }

    private func engine(holding offset: Int, continuation: Int?, withMap: Bool = false) throws -> (SessionEngine, NoteAudio) {
        let audio = NoteAudio()
        let repository = InMemorySessionRepository(items: [item.id: item])
        if withMap { repository.mapsByItemId[item.id] = mapItem }
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.charOffset = offset
        audio.continuation = continuation
        return (engine, audio)
    }

    func testParagraphForwardDuringANoteGoesOnWithTheSentenceAfterTheCitingOne() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: citingEnd)

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(audio.plays.last, citingEnd, "the next sentence of the main text, not the next paragraph")
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), citingEnd)
    }

    func testTheSameButtonOutsideANoteStillMovesByParagraph() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: nil)

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(audio.plays.last, secondParagraph)
    }

    func testSentenceForwardDuringANoteDoesNotSkipTheSentenceAfterIt() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: citingEnd)

        _ = try engine.skipForward(unit: "sentence")

        XCTAssertEqual(audio.plays.last, citingEnd)
    }

    func testTheDistanceAskedForDoesNotKeepTheNoteGoing() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: citingEnd)

        _ = try engine.skipForward(unit: "paragraph", minimumDistance: 30)

        XCTAssertEqual(audio.plays.last, citingEnd)
    }

    func testASectionSkipDuringANoteKeepsItsOwnRule() throws {
        let (engine, _) = try engine(holding: citingEnd, continuation: citingEnd)

        _ = try engine.skipForward(unit: "section")

        // A section is a fixed step of at least 500 characters, so in this short text it reaches the end; the note's
        // continuation (the citing sentence's end) plays no part in it.
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), text.count)
    }

    func testANoteWithNothingAfterItEndsTheText() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: text.count)
        let playsBefore = audio.plays.count
        let stopsBefore = audio.stops

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), text.count)
        XCTAssertEqual(audio.plays.count, playsBefore, "nothing is left to play")
        XCTAssertEqual(audio.stops, stopsBefore + 1)
    }

    func testAContinuationPastTheTextIsClampedToItsEnd() throws {
        let (engine, _) = try engine(holding: citingEnd, continuation: text.count + 500)

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), text.count)
    }

    func testAForwardSkipNeverGoesBackwardsWhateverTheClientSays() throws {
        let (engine, audio) = try engine(holding: secondParagraph, continuation: citingEnd)

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(audio.plays.last, secondParagraph)
    }

    func testASecondPressWhilePlayerIsStillOnTheNoteMovesOnByParagraph() throws {
        let (engine, audio) = try engine(holding: citingEnd, continuation: citingEnd)

        _ = try engine.skipForward(unit: "paragraph")
        XCTAssertEqual(audio.plays.last, citingEnd)
        // The player still answers that it is on the note (paused, or the next sentence is still rendering).
        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(audio.plays.last, secondParagraph)
    }

    func testAListeningMapsPrefaceDoesNotShiftWhereTheTextContinues() throws {
        let (engine, audio) = try engine(holding: 0, continuation: nil, withMap: true)
        let preface = prefaceLength
        XCTAssertGreaterThan(preface, 0, "the map puts a spoken preface ahead of the text")
        audio.charOffset = preface + citingEnd
        audio.continuation = preface + citingEnd

        _ = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), citingEnd)
        XCTAssertEqual(audio.plays.last, preface + citingEnd)
    }
}
