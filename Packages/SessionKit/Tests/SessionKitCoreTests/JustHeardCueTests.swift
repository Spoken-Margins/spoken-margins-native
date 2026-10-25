import XCTest
@testable import SessionKit

final class JustHeardCueTests: XCTestCase {
    func testKeepsTheLastTwoSentences() {
        let before = "First thing. Second thing is here. Third thing follows. Fourth thing ends it."
        XCTAssertEqual(JustHeardCue.excerpt(from: before), "Third thing follows. Fourth thing ends it.")
    }

    func testAShortPassageIsKeptWhole() {
        XCTAssertEqual(JustHeardCue.excerpt(from: "Only one sentence."), "Only one sentence.")
    }

    func testNoWordsMeansNoCue() {
        XCTAssertNil(JustHeardCue.excerpt(from: nil))
        XCTAssertNil(JustHeardCue.excerpt(from: ""))
        XCTAssertNil(JustHeardCue.excerpt(from: " \n\t "))
    }

    func testLinesAndRunsOfSpacesBecomeOneLine() {
        XCTAssertEqual(JustHeardCue.excerpt(from: "One  line\nbroken here.\n\nAnd  another."), "One line broken here. And another.")
    }

    func testALongSentenceKeepsItsEndFromAWordOnward() throws {
        let long = (1...80).map { "word\($0)" }.joined(separator: " ") + "."
        let cue = try XCTUnwrap(JustHeardCue.excerpt(from: long))
        XCTAssertTrue(cue.hasPrefix("…word"), cue)
        XCTAssertTrue(cue.hasSuffix("word80."), cue)
        XCTAssertLessThanOrEqual(cue.count, JustHeardCue.characterLimit + 1)
        XCTAssertFalse(cue.dropFirst().hasPrefix("ord"), "never starts mid-word")
    }

    func testAnUnpunctuatedTranscriptStillCuts() throws {
        let words = (1...100).map { "w\($0)" }.joined(separator: " ")
        let cue = try XCTUnwrap(JustHeardCue.excerpt(from: words))
        XCTAssertTrue(cue.hasSuffix("w100"), cue)
        XCTAssertLessThanOrEqual(cue.count, JustHeardCue.characterLimit + 1)
    }

    /// The splitter works the same on Apple platforms and Linux, which has no Foundation sentence boundaries (#2681).
    func testThePunctuationSplitterCutsAfterEndsThatASpaceFollows() {
        let rows: [(String, [String])] = [
            ("First thing. Second thing! Third thing? Fourth…", ["First thing.", "Second thing!", "Third thing?", "Fourth…"]),
            ("He said \"stop.\" Then left.", ["He said \"stop.\"", "Then left."]),
            ("Version 2.5 shipped. Done", ["Version 2.5 shipped.", "Done"]),
            ("no punctuation at all", ["no punctuation at all"]),
            ("Wait... what? (Really.) Yes.", ["Wait...", "what?", "(Really.)", "Yes."]),
            ("", []),
        ]
        for (text, expected) in rows {
            XCTAssertEqual(JustHeardCue.punctuationSentences(of: text), expected, text)
        }
    }

    /// Foundation's `.bySentences`, which this replaced, also ended a sentence at "Dr. ", so the two sentences
    /// kept are "Then Dr." and "Smith arrived late." and the cue reads as it did before #2681.
    func testAnAbbreviationReadsAsItDidWithFoundationsSentences() {
        XCTAssertEqual(JustHeardCue.excerpt(from: "It rained. Then Dr. Smith arrived late."), "Then Dr. Smith arrived late.")
    }

    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor", "delegate_interjection_to_canonical_runtime"]
        ]
    )

    private final class Reader: AudioPlaybackClient {
        var charOffset: Int?
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset }
        func pause() throws {}
        func currentCharOffset() -> Int? { charOffset }
        func currentPlaybackPosition() -> PlaybackPosition? {
            charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }
    }

    private final class Microphone: RecordingClient {
        func beginRecording() throws {}
        func cancelRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    /// The cue is the engine's own anchor words from when recording began, so it refers to that place even if
    /// the source moves on while the listener talks.
    func testARecordingShowsWhatWasHeardBeforeItBeganEvenIfThePlaceMovesOn() throws {
        let text = "Alpha came first. Bravo came second. Charlie came third. Delta came fourth. Echo is next."
        let item = Item(id: "article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let reader = Reader()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(items: [item.id: item]), audio: reader, recorder: Microphone())
        _ = try engine.startSession(itemId: item.id)
        XCTAssertNil(engine.recordingContextBefore, "nothing is recording yet")
        reader.charOffset = (text as NSString).range(of: "Echo is next").location

        _ = try engine.beginInterjection()
        let cue = try XCTUnwrap(JustHeardCue.excerpt(from: engine.recordingContextBefore))
        XCTAssertEqual(cue, "Charlie came third. Delta came fourth.")

        reader.charOffset = 0
        XCTAssertEqual(JustHeardCue.excerpt(from: engine.recordingContextBefore), cue, "the place was fixed when recording began")
    }

    func testARecordingAtTheStartOfTheSourceHasNoCue() throws {
        let item = Item(id: "article", title: "Article", mediaType: "text", text: "Opening sentence here. Another follows.", externalReference: nil, status: "ready")
        let reader = Reader()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(items: [item.id: item]), audio: reader, recorder: Microphone())
        _ = try engine.startSession(itemId: item.id)
        reader.charOffset = 0
        _ = try engine.beginInterjection()
        XCTAssertNil(JustHeardCue.excerpt(from: engine.recordingContextBefore))
    }
}
