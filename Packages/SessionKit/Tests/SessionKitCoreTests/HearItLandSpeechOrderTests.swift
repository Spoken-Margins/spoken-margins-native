import Foundation
import XCTest
@testable import SessionKit

/// #4713 / #4715: the playback comes first, then the speech ask. The model used to arm the speech card at the save with
/// `hearItLandWillRun: false`, so the card held the slot and the playback never started (a fresh install, where iOS's
/// answer is undecided, almost never heard its first Margin back).
final class HearItLandSpeechOrderTests: XCTestCase {
    private func order(
        _ kind: MarginHearing.Kind = .spoken, heard: Bool = false, hadBefore: Bool = false, heldVoice: Bool = false,
        sourcePlays: Bool = true, around: HearItLand.Surroundings = .clear
    ) -> HearItLand.Order {
        HearItLand.order(kind: kind, heardFirstMargin: heard, hadSavedMarginBefore: hadBefore, savedOverHeldVoice: heldVoice,
                         sourcePlaysAfterSave: sourcePlays, surroundings: around)
    }

    /// What the speech card does through a save, by the path the app takes: `Gate1AppModel.hearItLandWillPlayBack` answers
    /// `order.playsBack`, `finishInterjection` hands it to `transcribeAndRecordSavedSpokenMargin(hearItLandWillRun:)`, which
    /// asks `SpeechRecognitionAsk.Moment.forSavedMargin` and `SpeechAskController.spokenMarginSaved` for the card at the save;
    /// the playback's end (or its failure to start) is `SpeechAskController.hearItLandEnded`. The app never reads
    /// `Order.speechAtSave`, so this does not either.
    private func cardTimeline(
        _ order: HearItLand.Order, isWritten: Bool = false, access: SpeechRecognitionAccessState = .notDetermined
    ) -> (atSave: Bool, atEnd: Bool) {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        let atSave = SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: isWritten, hearItLandWillRun: order.playsBack)
            .map { ask.cardDue(at: $0, access: access, shownThisLaunchForReAsk: false) } ?? false
        let atEnd = order.playsBack ? ask.cardDue(at: .hearItLandEnded, access: access, shownThisLaunchForReAsk: false) : false
        return (atSave, atEnd)
    }

    func testAFirstSpokenSaveWithTheSpeechAnswerUndecidedPlaysBackAndTheCardWaits() {
        let chosen = order()
        XCTAssertEqual(chosen.plan, .playBack)
        XCTAssertEqual(chosen.speechAtSave, .spokenMarginSaved(hearItLandWillRun: true))
        XCTAssertEqual(chosen.speechAtPlaybackEnd, .hearItLandEnded)
        XCTAssertTrue(chosen.playsBack)
        let card = cardTimeline(chosen)
        XCTAssertFalse(card.atSave, "the card does not take the slot at the save")
        XCTAssertTrue(card.atEnd, "it is due when the playback ends")
    }

    /// The table: what runs first and what waits, for each way a spoken or written save can go.
    func testWhatRunsFirstAndWhatWaits() {
        let rows: [(String, HearItLand.Order, HearItLand.Plan, cardAtSave: Bool, cardAtEnd: Bool)] = [
            ("first spoken save", order(), .playBack, false, true),
            ("a later spoken save, event not fired", order(hadBefore: true), .playBack, false, true),
            ("spoken save from a paused source (Save & resume plays)", order(sourcePlays: true), .playBack, false, true),
            ("spoken save over a held voice: no playback, card at once", order(heldVoice: true), .none, true, false),
            ("spoken save that did not resume the source", order(sourcePlays: false), .none, true, false),
            ("returning listener (event already done)", order(heard: true), .none, true, false),
            ("app in the background", order(around: .init(appInForeground: false)), .none, true, false),
            ("recording again", order(around: .init(recordingAgain: true)), .none, true, false),
            ("another sheet up", order(around: .init(anotherSheetUp: true)), .none, true, false),
            ("written first Margin: no transcript to ask about", order(.written), .showWritten, false, false),
        ]
        for (name, chosen, plan, cardAtSave, cardAtEnd) in rows {
            XCTAssertEqual(chosen.plan, plan, name)
            let card = cardTimeline(chosen, isWritten: plan == .showWritten)
            XCTAssertEqual(card.atSave, cardAtSave, "\(name): card at the save")
            XCTAssertEqual(card.atEnd, cardAtEnd, "\(name): card at the playback's end")
            XCTAssertEqual(chosen.playsBack, plan == .playBack, "\(name): the app's answer to the speech ask")
        }
    }

    /// Once iOS has decided, there is no card at all, and the playback is unchanged.
    func testAnAnsweredSpeechPromptShowsNoCardAndStillPlaysBack() {
        let chosen = order()
        XCTAssertEqual(chosen.plan, .playBack)
        let card = cardTimeline(chosen, access: .authorized)
        XCTAssertFalse(card.atSave)
        XCTAssertFalse(card.atEnd)
    }
}
