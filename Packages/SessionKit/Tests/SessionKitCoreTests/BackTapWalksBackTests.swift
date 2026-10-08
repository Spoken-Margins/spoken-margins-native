import Foundation
import XCTest
@testable import SessionKit

/// #1102: in text narration, a Back tap went to the start of the sentence or paragraph being read. Playback
/// had moved a few characters on by the next tap, so that start was the nearest boundary again and repeated
/// taps stayed put. A Back tap near the start of a unit now goes to the start of the unit before it.
final class BackTapWalksBackTests: XCTestCase {
    /// Each sentence is far longer than three seconds of speech (about 42 characters at 1×).
    private let sentences = (0..<8).map {
        "Sentence number \($0) goes on for a good while, so it takes longer than three seconds to read aloud."
    }

    private func starts(separator: String) -> [Int] {
        var offsets: [Int] = []
        var next = 0
        for sentence in sentences {
            offsets.append(next)
            next += sentence.count + separator.count
        }
        return offsets
    }

    func testRepeatedBackTapsWalkBackOneSentenceEachWhilePlaybackCreepsPastEachStart() throws {
        let (engine, audio) = try playingEngine(separator: " ")
        let starts = starts(separator: " ")

        audio.currentOffset = starts[5] + 6
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[4], "first tap: a few characters in, so the sentence before")
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[3])
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[2])
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[1])
    }

    func testRepeatedBackTapsWalkBackOneParagraphEachWhilePlaybackCreepsPastEachStart() throws {
        let (engine, audio) = try playingEngine(separator: "\n\n")
        let starts = starts(separator: "\n\n")

        audio.currentOffset = starts[5] + 6
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph"), starts[4])
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph"), starts[3])
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph"), starts[2])
    }

    func testBackWellIntoAUnitRestartsItAndTheNextTapGoesToTheOneBefore() throws {
        for (unit, separator) in [("sentence", " "), ("paragraph", "\n\n")] {
            let (engine, audio) = try playingEngine(separator: separator)
            let starts = starts(separator: separator)

            audio.currentOffset = starts[5] + 60
            XCTAssertEqual(try tapBack(engine, audio, unit: unit), starts[5], "\(unit): well into it, Back restarts it")
            XCTAssertEqual(try tapBack(engine, audio, unit: unit), starts[4], "\(unit): then it walks back")
        }
    }

    func testBackExactlyAtAStartStillGoesToTheUnitBefore() throws {
        let (engine, audio) = try playingEngine(separator: " ")
        let starts = starts(separator: " ")

        audio.currentOffset = starts[5]
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[4])
    }

    func testBackInTheFirstUnitGoesToTheStartAndStaysThere() throws {
        let (engine, audio) = try playingEngine(separator: " ")

        audio.currentOffset = 6
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), 0)
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), 0)
    }

    func testTheWindowIsSecondsOfSpeechSoItWidensAtAFasterSpeed() throws {
        let (engine, audio) = try playingEngine(separator: " ")
        let starts = starts(separator: " ")

        audio.currentOffset = starts[5] + 60
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[5], "at 1×, 60 characters is more than three seconds in")

        _ = try engine.setPlaybackRate(2)
        audio.currentOffset = starts[5] + 60
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[4], "at 2×, 60 characters is under three seconds in")
    }

    /// A heading is a paragraph of a few words. Back landed on it, the speech read past it before the next tap,
    /// and that tap measured from the paragraph after it: back to the heading again, for good.
    func testRepeatedBackTapsWalkBackOverAHeadingShorterThanTheSpeechBetweenTaps() throws {
        let heading = "Why it matters"
        let paragraphs = [sentences[0], sentences[1], heading, sentences[3], sentences[4]]
        var starts: [Int] = []
        var next = 0
        for paragraph in paragraphs {
            starts.append(next)
            next += paragraph.count + 2
        }
        let (engine, audio) = try playingEngine(text: paragraphs.joined(separator: "\n\n"))

        audio.currentOffset = starts[3] + 6
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph", creep: 20), starts[2], "the heading")
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph", creep: 20), starts[1], "past the heading, not stuck on it")
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph", creep: 20), starts[0])
        XCTAssertEqual(try tapBack(engine, audio, unit: "paragraph", creep: 20), 0)
    }

    /// Abbreviations and ellipses end a "sentence" at every dot, so some units are a character or two long.
    func testRepeatedBackTapsKeepGoingOverUnitsOnlyACharacterOrTwoLong() throws {
        let text = "Wait... what happened here. ...Dr. Smith said the U.S. policy was fine... for now, and "
            + "that ended soon after. Nobody at the meeting could say why the rule had changed so quickly."
        let (engine, audio) = try playingEngine(text: text)

        audio.currentOffset = text.count - 6
        var landings: [Int] = []
        for _ in 0..<40 {
            landings.append(try tapBack(engine, audio, unit: "sentence"))
            if landings.last == 0 { break }
        }
        XCTAssertEqual(landings.last, 0, "reached the start: \(landings)")
        XCTAssertEqual(landings, landings.sorted(by: >), "every tap went further back: \(landings)")
        XCTAssertEqual(Set(landings).count, landings.count, "no tap landed where an earlier one did: \(landings)")
    }

    func testListeningOnAfterABackTapMakesTheNextTapRestartThatUnitAgain() throws {
        let (engine, audio) = try playingEngine(separator: " ")
        let starts = starts(separator: " ")

        audio.currentOffset = starts[5] + 6
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[4])
        audio.currentOffset = starts[4] + 60
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[4], "well into it again, so Back restarts it")
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), starts[3], "and the tap after that walks back")
    }

    func testTheWindowNeverPassesTheSpeedLimitsOrAnUnusableSpeed() {
        XCTAssertEqual(BackTapWindow.characters(atSpeed: 1), 42)
        XCTAssertEqual(BackTapWindow.characters(atSpeed: 2), 84)
        XCTAssertEqual(BackTapWindow.characters(atSpeed: 0), 42, "no speed counts as normal")
        XCTAssertEqual(BackTapWindow.characters(atSpeed: .nan), 42)
        XCTAssertGreaterThanOrEqual(BackTapWindow.characters(atSpeed: 0.0001), 1)
    }

    // MARK: - The remembered landing is forgotten when anything else moves the position (#1122)

    /// Short sentences, so the next unit starts inside the three-second window of the one before it.
    private let shortText = "Alpha. Bravo. Charlie. Delta. Echo. Foxtrot."

    private func start(of word: String, in text: String? = nil) -> Int {
        let text = text ?? shortText
        return text.distance(from: text.startIndex, to: text.range(of: word)!.lowerBound)
    }

    func testBackThenForwardThenBackReturnsToTheSentenceBeforeTheOneListenedTo() throws {
        let (engine, audio) = try playingEngine(text: shortText)
        audio.currentOffset = start(of: "Delta")

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
        XCTAssertEqual(try tapForward(engine, audio, unit: "sentence"), start(of: "Delta"))
        XCTAssertEqual(
            try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"),
            "Back from the start of Delta goes to Charlie, not to the sentence before the one Back landed on"
        )
    }

    func testBackThenASeekThenBackMeasuresFromWhereTheSeekPutTheListener() throws {
        let (engine, audio) = try playingEngine(text: shortText)
        audio.currentOffset = start(of: "Delta")

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
        _ = try engine.seekText(toCharOffset: start(of: "Echo"))
        audio.currentOffset = start(of: "Echo") + 5
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"))
    }

    func testBackThenAChapterJumpThenBackMeasuresFromTheChapter() throws {
        let chapters = [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: start(of: "Echo"), percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: start(of: "Echo"), endChar: shortText.count, percent: 68),
        ]
        let (engine, audio) = try playingEngine(text: shortText, chapters: chapters)
        audio.currentOffset = start(of: "Delta")

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
        _ = try engine.jumpToChapter(chapterId: "ch-2")
        audio.currentOffset = start(of: "Echo") + 5
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"))
    }

    func testBackThenAChapterSkipForwardThenBackMeasuresFromTheChapter() throws {
        let chapters = [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: start(of: "Delta"), percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: start(of: "Delta"), endChar: shortText.count, percent: 52),
        ]
        let (engine, audio) = try playingEngine(text: shortText, chapters: chapters)
        audio.currentOffset = start(of: "Delta")

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
        XCTAssertEqual(try tapForward(engine, audio, unit: "chapter"), start(of: "Delta"))
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
    }

    func testBackThenAChapterSkipBackThenBackMeasuresFromTheChapter() throws {
        let chapters = [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: start(of: "Echo"), percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: start(of: "Echo"), endChar: shortText.count, percent: 68),
        ]
        let (engine, audio) = try playingEngine(text: shortText, chapters: chapters)
        audio.currentOffset = start(of: "Echo") + 5

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence", creep: 10), start(of: "Delta"))
        XCTAssertEqual(try tapBack(engine, audio, unit: "chapter"), start(of: "Echo"), "ten characters on, the chapter start is behind")
        XCTAssertEqual(
            try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"),
            "five characters into Echo, the chapter start, Back goes to the sentence before it"
        )
    }

    /// Pausing doesn't move the listener, so the tap after a resume still reads as the walk-back it is. Thirty-two
    /// is four characters into Echo; a landing forgotten at the pause would put Back on Delta, the sentence before.
    func testPausingAndResumingBetweenBackTapsKeepsTheWalkBackGoing() throws {
        let (engine, audio) = try playingEngine(text: shortText)
        audio.currentOffset = start(of: "Echo") + 5

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"))
        _ = try engine.pause()
        _ = try engine.resumePlayback()
        audio.currentOffset = start(of: "Delta") + 9
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
    }

    func testBackThenPlayingTheSourceFromTheBeginningThenBackMeasuresFromThere() throws {
        let (engine, audio) = try playingEngine(text: shortText)
        audio.currentOffset = start(of: "Delta")

        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Charlie"))
        _ = try engine.playSourceFromBeginning()
        audio.currentOffset = start(of: "Echo")
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"))
    }

    /// A Margin saved while playing resumes at the start of its own sentence, which is a move too.
    func testBackThenASavedMarginThenBackMeasuresFromWhereTheMarginResumed() throws {
        let (engine, audio) = try playingEngine(text: shortText)
        audio.currentOffset = start(of: "Delta")
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence", creep: 0), start(of: "Charlie"))

        audio.currentOffset = start(of: "Echo") + 5
        let capture = try engine.beginWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A written thought.")
        XCTAssertEqual(audio.currentOffset, start(of: "Echo"), "the Margin resumes at the start of Echo")

        audio.currentOffset = start(of: "Echo") + 5
        XCTAssertEqual(try tapBack(engine, audio, unit: "sentence"), start(of: "Delta"))
    }

    // MARK: - Fixture

    /// One Back tap, then the player starting where the tap put it and reading a few characters on before the
    /// next tap, as it does on the phone. Returns where the tap landed.
    private func tapBack(_ engine: SessionEngine, _ audio: TextSpeechClient, unit: String, creep: Int = 5) throws -> Int {
        _ = try engine.skipBack(unit: unit)
        let landed = try XCTUnwrap(engine.currentSession?.position.charOffset)
        audio.currentOffset = landed + creep
        return landed
    }

    /// One Forward tap, then the player reading a few characters on from where the tap put it.
    private func tapForward(_ engine: SessionEngine, _ audio: TextSpeechClient, unit: String, creep: Int = 5) throws -> Int {
        _ = try engine.skipForward(unit: unit)
        let landed = try XCTUnwrap(engine.currentSession?.position.charOffset)
        audio.currentOffset = landed + creep
        return landed
    }

    private func playingEngine(separator: String) throws -> (SessionEngine, TextSpeechClient) {
        try playingEngine(text: sentences.joined(separator: separator))
    }

    private func playingEngine(text: String, chapters: [Chapter] = []) throws -> (SessionEngine, TextSpeechClient) {
        let item = Item(
            id: "item-back", title: "Back", mediaType: "text",
            text: text, externalReference: nil, status: "ready"
        )
        let repository = InMemorySessionRepository(items: [item.id: item])
        if !chapters.isEmpty {
            repository.mapsByItemId[item.id] = ListeningMap(id: "map-back", itemId: item.id, overview: "", chapters: chapters)
        }
        let audio = TextSpeechClient()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online", displayName: "Phone/Tablet Online",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"], "timeline": ["chapter_timing"]]
            ),
            repository: repository,
            audio: audio
        )
        _ = try engine.startSession(itemId: item.id)
        return (engine, audio)
    }
}

/// A speech player that reads text from wherever it was told to start, and whose position the test moves.
private final class TextSpeechClient: AudioPlaybackClient {
    var currentOffset: Int?

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { currentOffset = 0 }
    func play(targetId: String, from charOffset: Int) throws { currentOffset = charOffset }
    func pause() throws {}

    func currentPlaybackPosition() -> PlaybackPosition? {
        currentOffset.map {
            PlaybackPosition(targetId: "target", textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange)
        }
    }
}
