import Foundation
import XCTest
@testable import SessionKit

/// Hear it land (#4713): whether a just-saved Margin plays back in place, and the card words and lead-in that go with it.
final class HearItLandTests: XCTestCase {
    private func plan(
        _ kind: MarginHearing.Kind = .spoken, heard: Bool = false, hadBefore: Bool = false, heldVoice: Bool = false,
        sourcePlays: Bool = true, around: HearItLand.Surroundings = .clear
    ) -> HearItLand.Plan {
        HearItLand.plan(kind: kind, heardFirstMargin: heard, hadSavedMarginBefore: hadBefore, savedOverHeldVoice: heldVoice,
                        sourcePlaysAfterSave: sourcePlays, surroundings: around)
    }

    func testFirstSpokenMarginPlaysBack() {
        XCTAssertEqual(plan(), .playBack)
    }

    func testALaterSpokenMarginPlaysBackWhileTheEventHasNotFired() {
        XCTAssertEqual(plan(hadBefore: true), .playBack, "the first playback was skipped or stopped (Default 1)")
    }

    func testNothingPlaysOrShowsOnceTheFirstMarginWasHeard() {
        for kind in [MarginHearing.Kind.spoken, .written] {
            for hadBefore in [false, true] {
                XCTAssertEqual(plan(kind, heard: true, hadBefore: hadBefore), .none, "\(kind) hadBefore=\(hadBefore)")
            }
        }
    }

    func testAWrittenMarginShowsItsCardAndNeverPlays() {
        XCTAssertEqual(plan(.written), .showWritten)
        XCTAssertEqual(plan(.written, hadBefore: true), .showWritten)
        XCTAssertEqual(plan(.written, sourcePlays: false), .showWritten, "written while paused stays paused (Default 3)")
    }

    func testASpokenSaveOverAHeldVoiceGetsNoPlayback() {
        XCTAssertEqual(plan(heldVoice: true), .none)
    }

    func testASpokenSaveThatDoesNotResumeTheSourceGetsNoPlayback() {
        XCTAssertEqual(plan(sourcePlays: false), .none)
    }

    func testEachSurroundingThatOwnsTheScreenOrTheMicrophoneStopsPlayback() {
        let cases: [(String, HearItLand.Surroundings)] = [
            ("app in the background", .init(appInForeground: false)),
            ("recording again", .init(recordingAgain: true)),
            ("another sheet up", .init(anotherSheetUp: true)),
        ]
        for (name, around) in cases {
            XCTAssertEqual(plan(around: around), .none, name)
        }
    }

    func testSurroundingsDoNotHideTheWrittenCard() {
        let busy = HearItLand.Surroundings(appInForeground: false, recordingAgain: true, anotherSheetUp: true)
        XCTAssertEqual(plan(.written, around: busy), .showWritten)
    }

    func testTheLeadInIsFiveSecondsAndTheSourceCarriesOn() {
        let rule = ListeningMoment.rule(for: .hearItLand)
        XCTAssertEqual(rule.leadInMs, 5_000)
        XCTAssertEqual(rule.carryOn, .sourceContinues)
        XCTAssertEqual(ListeningMoment.rule(for: .playThisMoment).leadInMs, 30_000, "Play this moment keeps its thirty seconds")
    }

    func testTheLeadInCardSaysItIsYoursAndOtherRunsKeepTheOldLine() {
        let landing = PinnedMarginCard(subject: .yours, stage: .comingUp(msRemaining: 5_000), run: .hearItLand)
        XCTAssertEqual(landing.headline, "Your Margin in 0:05")
        XCTAssertEqual(landing.detail, "That's yours now, pinned to this moment.")
        let moment = PinnedMarginCard(subject: .yours, stage: .comingUp(msRemaining: 8_000), run: .moment)
        XCTAssertEqual(moment.detail, "It plays by itself when the episode gets there.")
    }

    func testTheVoiceStageOfHearItLandKeepsTheOrdinaryWords() {
        let speaking = PinnedMarginCard(subject: .yours, stage: .speaking, voiceTime: "0:04 of 0:09", run: .hearItLand)
        XCTAssertEqual(speaking.headline, "Your Margin")
        XCTAssertEqual(speaking.detail, "0:04 of 0:09 · Episode paused while it plays.")
    }
}
