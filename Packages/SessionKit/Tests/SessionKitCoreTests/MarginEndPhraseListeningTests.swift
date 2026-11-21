import Foundation
import SessionKit
import XCTest

/// #3940, PR 3: when a Margin listens for its end phrase, and what the listening decides. The microphone and the
/// recogniser are the app's; these are the rules around them.
final class MarginEndPhraseListeningTests: XCTestCase {
    // MARK: Availability

    private func decide(
        on: Bool = true, speech: SpeechRecognitionAccessState = .authorized, language: String? = "en", hot: Bool = false
    ) -> MarginEndPhraseAvailability {
        MarginEndPhraseAvailability.decide(isSwitchedOn: on, speech: speech, languageCode: language, thermalIsSeriousOrWorse: hot)
    }

    func testListeningIsOnWhenEverythingAllowsIt() {
        XCTAssertEqual(decide(), .available)
        XCTAssertEqual(decide(language: "EN"), .available, "the code's case doesn't matter")
    }

    func testEachReasonTurnsListeningOffAndSaysWhy() {
        XCTAssertEqual(decide(on: false), .off(.switchedOff))
        XCTAssertEqual(decide(language: "fr"), .off(.languageNotEnglish))
        XCTAssertEqual(decide(language: nil), .off(.languageNotEnglish))
        XCTAssertEqual(decide(speech: .notDetermined), .off(.speechNotAsked), "never asked from the recording screen")
        XCTAssertEqual(decide(speech: .denied), .off(.speechDenied))
        XCTAssertEqual(decide(speech: .restricted), .off(.speechDenied))
        XCTAssertEqual(decide(hot: true), .off(.tooHot))
    }

    func testTheSwitchIsOnUntilTheListenerTurnsItOff() {
        XCTAssertTrue(MarginEndPhraseAvailability.isSwitchedOn(stored: nil))
        XCTAssertTrue(MarginEndPhraseAvailability.isSwitchedOn(stored: true))
        XCTAssertFalse(MarginEndPhraseAvailability.isSwitchedOn(stored: false))
    }

    // MARK: The decider

    private func word(_ text: String, _ start: Int, _ end: Int) -> MarginEndPhraseWord {
        MarginEndPhraseWord(text: text, startMs: start, endMs: end)
    }

    func testThePhraseEndsAMarginOnlyAfterTheConfirmingSecondAndTheDeliveryLag() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("that", 5_000, 5_300), word("is", 5_400, 5_600)], isFinal: false, sinceStartMs: 5_800), .unchanged)
        // "stop margin" ends at 7,300.
        XCTAssertEqual(decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400), .finishing)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_000), .unchanged)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_299), .unchanged, "1.0 s of audio plus 1.0 s of delivery lag")
        XCTAssertEqual(decider.tick(sinceStartMs: 9_300), .end)
    }

    func testItEndsOnceHoweverOftenTheSamePhraseIsHeard() {
        var decider = MarginEndPhraseDecider()
        _ = decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_300), .end)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_400), .unchanged)
        XCTAssertEqual(decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: true, sinceStartMs: 9_500), .unchanged)
        XCTAssertEqual(decider.tick(sinceStartMs: 60_000), .unchanged)
    }

    func testAWordAfterThePhraseCancelsTheFinishingAndTheHintReturns() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400), .finishing)
        XCTAssertEqual(decider.receive([word("notes", 7_800, 8_100)], isFinal: false, sinceStartMs: 8_700), .listening)
        XCTAssertEqual(decider.tick(sinceStartMs: 30_000), .unchanged, "the phrase is no longer the last words")
    }

    func testNothingEndsAfterAnyQuiet() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("hello", 2_000, 2_300)], isFinal: true, sinceStartMs: 3_000), .unchanged)
        for ms in stride(from: 3_000, through: 10 * 60_000, by: 250) {
            XCTAssertEqual(decider.tick(sinceStartMs: ms), .unchanged, "at \(ms) ms")
        }
    }

    func testAPhraseInTheFirstSecondDoesNothing() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("stop", 100, 400), word("margin", 500, 800)], isFinal: false, sinceStartMs: 2_000), .unchanged)
        XCTAssertEqual(decider.tick(sinceStartMs: 5_000), .unchanged)
    }

    func testAFinalResultAfterAGuessGivesTheSameEnd() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400), .finishing)
        XCTAssertEqual(decider.receive([word("Stop", 6_600, 6_900), word("margin.", 7_000, 7_300)], isFinal: true, sinceStartMs: 8_900), .unchanged)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_300), .end)
    }

    func testAGuessRevisedToNothingNeverEnds() {
        var decider = MarginEndPhraseDecider()
        XCTAssertEqual(decider.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400, resultStartMs: 6_600), .finishing)
        // The recogniser takes the guess back: an empty volatile result for audio from 6,600 on.
        XCTAssertEqual(decider.receive([], isFinal: false, sinceStartMs: 8_700, resultStartMs: 6_600), .listening)
        XCTAssertEqual(decider.tick(sinceStartMs: 9_300), .unchanged)
        XCTAssertEqual(decider.tick(sinceStartMs: 60_000), .unchanged, "a withdrawn phrase is never confirmed")
    }

    func testAFinalThatStartsEarlierThanItsFirstWordClearsTheGuessFromItsOwnStart() {
        var decider = MarginEndPhraseDecider()
        // The guess starts at "okay" (6,300); the final result's range starts there too but its words start later.
        XCTAssertEqual(decider.receive([word("okay", 6_300, 6_500), word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400, resultStartMs: 6_300), .finishing)
        XCTAssertEqual(decider.receive([word("okay", 6_300, 6_500), word("stop", 6_600, 6_900), word("marching", 7_000, 7_300)], isFinal: true, sinceStartMs: 8_700, resultStartMs: 6_300), .listening)
        XCTAssertEqual(decider.tick(sinceStartMs: 60_000), .unchanged)
    }

    func testAFinalThatIsEmptyOrShorterThanTheGuessTakesTheGuessBack() {
        // An empty final for the stretch the guess covered.
        var empty = MarginEndPhraseDecider()
        XCTAssertEqual(empty.receive([word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400, resultStartMs: 6_600), .finishing)
        XCTAssertEqual(empty.receive([], isFinal: true, sinceStartMs: 8_700, resultStartMs: 6_600, resultEndMs: 7_300), .listening)
        XCTAssertEqual(empty.tick(sinceStartMs: 60_000), .unchanged)
        // A final that stops short of the guess: "okay stop margin" becomes "okay stop".
        var shorter = MarginEndPhraseDecider()
        XCTAssertEqual(shorter.receive([word("okay", 6_300, 6_500), word("stop", 6_600, 6_900), word("margin", 7_000, 7_300)], isFinal: false, sinceStartMs: 8_400, resultStartMs: 6_300), .finishing)
        XCTAssertEqual(shorter.receive([word("okay", 6_300, 6_500), word("stop", 6_600, 6_900)], isFinal: true, sinceStartMs: 8_700, resultStartMs: 6_300, resultEndMs: 7_300), .listening)
        XCTAssertEqual(shorter.tick(sinceStartMs: 60_000), .unchanged)
    }
}
