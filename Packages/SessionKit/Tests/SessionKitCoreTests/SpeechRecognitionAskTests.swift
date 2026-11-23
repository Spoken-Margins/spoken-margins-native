import XCTest
@testable import SessionKit

/// #4715 PR 1 / #5016: the app asks about Speech Recognition in one line after the first spoken Margin is saved, never
/// iOS in the middle of a save. These pin the rule the card and the hold on iOS's prompt both follow.
final class SpeechRecognitionAskTests: XCTestCase {
    private let allAccess: [SpeechRecognitionAccessState] = [.authorized, .notDetermined, .denied, .restricted]
    private let saved = SpeechRecognitionAsk.Moment.spokenMarginSaved(hearItLandWillRun: false)

    // MARK: Storage

    func testStoredAnswerTable() {
        let table: [(String?, SpeechRecognitionAsk.Answer)] = [
            (nil, .unanswered), ("", .unanswered), ("unanswered", .unanswered), ("notNow", .notNow), ("yes", .yes),
            ("Yes", .unanswered), (" yes", .unanswered), ("no", .unanswered), ("true", .unanswered),
            ("notnow", .unanswered), (String(repeating: "y", count: 10_000), .unanswered)
        ]
        for (stored, expected) in table {
            XCTAssertEqual(SpeechRecognitionAsk(storedAnswer: stored).answer, expected, "stored \(String(describing: stored))")
        }
    }

    func testAnswerRoundTripsThroughItsStoredValue() {
        for answer in [SpeechRecognitionAsk.Answer.unanswered, .notNow, .yes] {
            var ask = SpeechRecognitionAsk(storedAnswer: nil)
            ask.answered(answer)
            XCTAssertEqual(SpeechRecognitionAsk(storedAnswer: ask.storedAnswer).answer, answer)
        }
        XCTAssertEqual(SpeechRecognitionAsk.storageKey, "speechRecognitionAskV1")
    }

    // MARK: Holding iOS's prompt (Design section 1)

    func testSystemMayAskOnlyAfterYesAndOnlyWhileTheAnswerIsOpen() {
        for answer in [SpeechRecognitionAsk.Answer.unanswered, .notNow, .yes] {
            var ask = SpeechRecognitionAsk(storedAnswer: nil)
            ask.answered(answer)
            for access in allAccess {
                let expected = answer == .yes && access == .notDetermined
                XCTAssertEqual(ask.mayAskSystem(access: access), expected, "\(answer) / \(access)")
            }
        }
    }

    // MARK: When the card shows

    /// `cardAfterFirstSpokenSave`
    func testCardAfterFirstSpokenSave() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        XCTAssertTrue(ask.cardDue(at: saved, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    /// `cardAfterHearItLand` (PR 2's input; PR 1 always passes false, and the rule is already here)
    func testCardWaitsForHearItLandWhenItWillRun() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        XCTAssertFalse(ask.cardDue(at: .spokenMarginSaved(hearItLandWillRun: true), access: .notDetermined, shownThisLaunchForReAsk: false))
        XCTAssertTrue(ask.cardDue(at: .hearItLandEnded, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    func testHearItLandEndedWithNoSpokenMarginSavedBringsNoCard() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        XCTAssertFalse(ask.cardDue(at: .hearItLandEnded, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    /// `writtenMarginBringsNoCard`
    func testWrittenMarginBringsNoCard() {
        XCTAssertNil(SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: true, hearItLandWillRun: false))
        XCTAssertNil(SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: true, hearItLandWillRun: true))
        XCTAssertEqual(
            SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: false, hearItLandWillRun: false),
            .spokenMarginSaved(hearItLandWillRun: false))
        let ask = SpeechRecognitionAsk(storedAnswer: nil)
        XCTAssertFalse(ask.isOwed(access: .notDetermined), "nothing saved, nothing owed")
    }

    /// `decidedAccessNeverShowsCard` and `restrictedNeverShowsCard`
    func testNoCardWhenIOSHasAlreadyDecided() {
        let moments: [SpeechRecognitionAsk.Moment] = [saved, .hearItLandEnded, .reachedForText]
        for access in [SpeechRecognitionAccessState.authorized, .denied, .restricted] {
            for moment in moments {
                for stored in [nil, "unanswered", "notNow", "yes"] {
                    var ask = SpeechRecognitionAsk(storedAnswer: stored, hasSavedSpokenMargin: true)
                    XCTAssertFalse(ask.cardDue(at: moment, access: access, shownThisLaunchForReAsk: false), "\(access) \(moment) \(String(describing: stored))")
                    XCTAssertFalse(ask.isOwed(access: access))
                }
            }
        }
    }

    /// Closed while iOS's prompt was up: the Yes was never answered, so it is not carried into the next launch.
    func testAYesThatIOSNeverAnsweredIsDroppedAtLaunch() {
        let table: [(String?, SpeechRecognitionAccessState, String?)] = [
            ("yes", .notDetermined, nil),
            ("yes", .authorized, "yes"), ("yes", .denied, "yes"), ("yes", .restricted, "yes"),
            ("notNow", .notDetermined, "notNow"), ("unanswered", .notDetermined, "unanswered"), (nil, .notDetermined, nil),
            ("garbage", .notDetermined, "garbage"), ("", .notDetermined, "")
        ]
        for (stored, access, expected) in table {
            XCTAssertEqual(SpeechRecognitionAsk.answerToCarryIntoLaunch(stored: stored, access: access), expected, "\(String(describing: stored)) \(access)")
        }
        // The card comes back and iOS stays closed.
        let carried = SpeechRecognitionAsk.answerToCarryIntoLaunch(stored: "yes", access: .notDetermined)
        let ask = SpeechRecognitionAsk(storedAnswer: carried, hasSavedSpokenMargin: true)
        XCTAssertTrue(ask.isOwed(access: .notDetermined))
        XCTAssertFalse(ask.mayAskSystem(access: .notDetermined))
    }

    /// Get Transcript always reaches the system prompt or the card while iOS is undecided.
    func testGetTranscriptAlwaysGetsSomewhere() {
        for stored in [nil, "unanswered", "notNow", "garbage"] as [String?] {
            XCTAssertEqual(SpeechRecognitionAsk(storedAnswer: stored).getTranscriptStep(access: .notDetermined), .showCard, "\(String(describing: stored))")
        }
        XCTAssertEqual(SpeechRecognitionAsk(storedAnswer: "yes").getTranscriptStep(access: .notDetermined), .askSystem)
        for access in [SpeechRecognitionAccessState.authorized, .denied, .restricted] {
            for stored in [nil, "notNow", "yes"] as [String?] {
                XCTAssertEqual(SpeechRecognitionAsk(storedAnswer: stored).getTranscriptStep(access: access), .settle)
            }
        }
    }

    /// `unansweredSurvivesRelaunch`: the Margin on the waiting list is what arms the card in a new launch.
    func testUnansweredCardIsOwedAfterRelaunchWhileAMarginWaits() {
        XCTAssertTrue(SpeechRecognitionAsk(storedAnswer: nil, hasSavedSpokenMargin: true).isOwed(access: .notDetermined))
        XCTAssertFalse(SpeechRecognitionAsk(storedAnswer: nil, hasSavedSpokenMargin: false).isOwed(access: .notDetermined))
        XCTAssertFalse(SpeechRecognitionAsk(storedAnswer: "notNow", hasSavedSpokenMargin: true).isOwed(access: .notDetermined))
        XCTAssertFalse(SpeechRecognitionAsk(storedAnswer: "yes", hasSavedSpokenMargin: true).isOwed(access: .notDetermined))
    }

    func testSeveralSpokenMarginsBeforeAnAnswerKeepTheCardOwed() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        for _ in 0..<3 {
            XCTAssertTrue(ask.cardDue(at: saved, access: .notDetermined, shownThisLaunchForReAsk: false))
        }
        XCTAssertTrue(ask.isOwed(access: .notDetermined))
    }

    // MARK: Answers

    func testYesAndNotNowTakeTheCardAway() {
        for answer in [SpeechRecognitionAsk.Answer.yes, .notNow] {
            var ask = SpeechRecognitionAsk(storedAnswer: nil)
            _ = ask.cardDue(at: saved, access: .notDetermined, shownThisLaunchForReAsk: false)
            ask.answered(answer)
            XCTAssertFalse(ask.isOwed(access: .notDetermined), "\(answer)")
            XCTAssertFalse(ask.cardDue(at: saved, access: .notDetermined, shownThisLaunchForReAsk: false))
        }
    }

    /// `yesAllowRetriesWaiting` / `yesDenyShowsTodaysWording`: after Yes the card never comes back for any reach.
    /// The card that was drawn on the Margins tab or a Margin's screen moves to Now when the listener leaves, unless the
    /// question is over (a Yes, or iOS has decided). A Not now that was re-asked is still unanswered, so it stays.
    func testCardStaysForNowWhenTheListenerLeavesItsSurface() {
        for access in allAccess {
            for answer in [SpeechRecognitionAsk.Answer.unanswered, .notNow, .yes] {
                var ask = SpeechRecognitionAsk(storedAnswer: nil)
                ask.answered(answer)
                XCTAssertEqual(ask.cardStaysOnNowAfterSurfaceLeft(access: access), access == .notDetermined && answer != .yes,
                               "\(access) \(answer)")
            }
        }
    }

    func testYesIsFinal() {
        let moments: [SpeechRecognitionAsk.Moment] = [saved, .hearItLandEnded, .reachedForText]
        for moment in moments {
            var ask = SpeechRecognitionAsk(storedAnswer: "yes", hasSavedSpokenMargin: true)
            XCTAssertFalse(ask.cardDue(at: moment, access: .notDetermined, shownThisLaunchForReAsk: false), "\(moment)")
        }
    }

    // MARK: Re-asks (Design section 2)

    /// `notNowReasksOnSearch` and `notNowReasksOnCopy`: both are the one moment, "reached for text".
    func testNotNowComesBackWhenTheListenerReachesForText() {
        var ask = SpeechRecognitionAsk(storedAnswer: "notNow")
        XCTAssertTrue(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    /// `reaskOncePerLaunch`
    func testAReaskShowsOncePerLaunchAtMost() {
        var ask = SpeechRecognitionAsk(storedAnswer: "notNow")
        XCTAssertFalse(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: true))
    }

    func testNotNowIsNotAskedAgainByASave() {
        var ask = SpeechRecognitionAsk(storedAnswer: "notNow")
        XCTAssertFalse(ask.cardDue(at: saved, access: .notDetermined, shownThisLaunchForReAsk: false))
        XCTAssertFalse(ask.cardDue(at: .hearItLandEnded, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    func testReachingForTextBeforeAnyAnswerOrSavedMarginAsksNothing() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        XCTAssertFalse(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    func testReachingForTextWhileTheFirstCardIsStillOwedShowsIt() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil, hasSavedSpokenMargin: true)
        XCTAssertTrue(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: true))
    }
}

/// The ids of the spoken Margins whose transcription met the hold (Design section 3).
final class SpeechAskWaitingListTests: XCTestCase {
    func testStoredTable() {
        let table: [([String]?, [String])] = [
            (nil, []), ([], []), (["a"], ["a"]), (["a", "b"], ["a", "b"]), (["a", "a", "b"], ["a", "b"]),
            (["", "a"], ["a"]), (["b", "a"], ["b", "a"])
        ]
        for (stored, expected) in table {
            XCTAssertEqual(SpeechAskWaitingList(stored: stored).ids, expected, "\(String(describing: stored))")
        }
    }

    func testAddKeepsOldestFirstAndIgnoresRepeatsAndEmpties() {
        var list = SpeechAskWaitingList(stored: nil)
        XCTAssertTrue(list.add("m1"))
        XCTAssertTrue(list.add("m2"))
        XCTAssertFalse(list.add("m1"))
        XCTAssertFalse(list.add(""))
        XCTAssertEqual(list.ids, ["m1", "m2"])
        XCTAssertEqual(list.stored, ["m1", "m2"])
        XCTAssertTrue(list.contains("m2"))
        XCTAssertFalse(list.contains("m3"))
        XCTAssertFalse(list.contains(""))
    }

    func testClearEmptiesAndIsRepeatable() {
        var list = SpeechAskWaitingList(stored: ["m1"])
        list.clear()
        list.clear()
        XCTAssertTrue(list.ids.isEmpty)
        XCTAssertTrue(list.add("m1"), "a Margin can wait again after a clear")
    }

    /// A Margin reads "No transcript yet." only while it is on the list and iOS is still undecided.
    func testAMarginIsWaitingOnlyWhileListedAndIOSIsUndecided() {
        let list = SpeechAskWaitingList(stored: ["m1"])
        for access in [SpeechRecognitionAccessState.authorized, .notDetermined, .denied, .restricted] {
            XCTAssertEqual(list.isWaiting("m1", access: access), access == .notDetermined, "\(access)")
            XCTAssertFalse(list.isWaiting("m2", access: access), "\(access)")
        }
        XCTAssertFalse(list.isWaiting("", access: .notDetermined))
    }

    func testAMarginWaitingArmsTheCard() {
        XCTAssertTrue(SpeechAskWaitingList(stored: ["m1"]).hasWaitingMargin)
        XCTAssertFalse(SpeechAskWaitingList(stored: nil).hasWaitingMargin)
    }
}
