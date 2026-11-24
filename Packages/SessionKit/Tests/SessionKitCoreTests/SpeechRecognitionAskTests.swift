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

/// Held transcription (director's Default taken on #4715, 2026-11-23).
final class SpeechAskHeldTranscriptionTests: XCTestCase {
    /// The audits on #5124: a listener who has never recorded in the player opens a friend's podcast packet whose
    /// placement needs a transcript (17:14Z), or records spoken Margins only in a live session, on the Watch or by the
    /// Shortcut (18:59Z). Those holds make the card owed: a spoken Margin from any surface in the Margins words, a
    /// friend's packet in its own. The other held paths wait quietly.
    func testHeldTranscriptionOwesTheCardForASpokenMarginOrAFriendsPacketTable() {
        typealias Row = (name: String, answer: SpeechRecognitionAsk.Answer, spokenMargin: Bool, held: [HeldTranscription],
                         owed: Bool, wording: SpeechRecognitionAsk.CardWording)
        let rows: [Row] = [
            ("never recorded in the player, live-session Margin held", .unanswered, false, [.liveSessionMargin], true, .margins),
            ("never recorded in the player, Watch Margin held", .unanswered, false, [.watchMargin], true, .margins),
            ("never recorded in the player, Shortcut Margin held", .unanswered, false, [.shortcutMargin], true, .margins),
            ("player Margin held", .unanswered, false, [.playerMargin], true, .margins),
            ("friend's packet then a Watch Margin held", .unanswered, false, [.friendPacketPlacement, .watchMargin], true, .margins),
            ("episode map then a live-session Margin held", .unanswered, false, [.episodeMap, .liveSessionMargin], true, .margins),
            ("answered Not now, live-session Margin held", .notNow, false, [.liveSessionMargin], false, .margins),
            ("answered Yes, Shortcut Margin held", .yes, false, [.shortcutMargin], false, .margins),
            ("never recorded, Just Heard peek held", .unanswered, false, [.justHeardPeek], false, .margins),
            ("never recorded, spoken note held", .unanswered, false, [.spokenNote], true, .margins),
            ("friend's packet then a spoken note held", .unanswered, false, [.friendPacketPlacement, .spokenNote], true, .margins),
            ("answered Not now, spoken note held", .notNow, false, [.spokenNote], false, .margins),
            ("never recorded, friend's packet held", .unanswered, false, [.friendPacketPlacement], true, .friendPlacement),
            ("never recorded, background episode map held", .unanswered, false, [.episodeMap], false, .margins),
            ("never recorded, episode map they asked for held", .unanswered, false, [.listenerEpisodeMap], true, .listeningMap),
            ("answered Not now, episode map they asked for held", .notNow, false, [.listenerEpisodeMap], false, .listeningMap),
            ("episode map they asked for, then a friend's packet", .unanswered, false, [.listenerEpisodeMap, .friendPacketPlacement], true, .friendPlacement),
            ("episode map they asked for, then a spoken note", .unanswered, false, [.listenerEpisodeMap, .spokenNote], true, .margins),
            ("spoken Margin and episode map they asked for", .unanswered, true, [.listenerEpisodeMap], true, .margins),
            ("never recorded, source window held", .unanswered, false, [.sourceWindow], false, .margins),
            ("never recorded, publisher map held", .unanswered, false, [.publisherTextMap], false, .margins),
            ("never recorded, episode map and source window", .unanswered, false, [.episodeMap, .sourceWindow], false, .margins),
            ("never recorded, nothing held", .unanswered, false, [], false, .margins),
            ("answered Not now, friend's packet held", .notNow, false, [.friendPacketPlacement], false, .friendPlacement),
            ("answered Yes, friend's packet held", .yes, false, [.friendPacketPlacement], false, .friendPlacement),
            ("spoken Margin and friend's packet held", .unanswered, true, [.friendPacketPlacement], true, .margins),
            ("spoken Margin, nothing held", .unanswered, true, [], true, .margins),
        ]
        for row in rows {
            var ask = SpeechRecognitionAsk(storedAnswer: row.answer.rawValue, hasSavedSpokenMargin: row.spokenMargin)
            for kind in row.held { ask.transcriptionHeld(kind) }
            XCTAssertEqual(ask.isOwed(access: .notDetermined), row.owed, row.name)
            XCTAssertEqual(ask.cardWording, row.wording, row.name)
            for decided in [SpeechRecognitionAccessState.authorized, .denied, .restricted] {
                XCTAssertFalse(ask.isOwed(access: decided), "\(row.name) / \(decided): iOS has decided")
            }
        }
    }

    /// The friend's words name the reason in one line; a spoken Margin saved later switches the card to the Margins words.
    func testFriendWordingGivesWayOnceASpokenMarginIsSaved() {
        XCTAssertEqual(SpeechRecognitionAsk.CardWording.friendPlacement.headline,
                       "Your friend's Margins land at the right moment if you allow speech recognition.")
        XCTAssertEqual(SpeechRecognitionAsk.CardWording.margins.headline, "Want your Margins as text too?")
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        ask.transcriptionHeld(.friendPacketPlacement)
        XCTAssertTrue(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: false),
                      "a friend's hold is a reason to show the card when the listener reaches for text")
        XCTAssertEqual(ask.cardWording, .friendPlacement)
        _ = ask.cardDue(at: .spokenMarginSaved(hearItLandWillRun: false), access: .notDetermined, shownThisLaunchForReAsk: false)
        XCTAssertEqual(ask.cardWording, .margins)
    }

    /// The pre-audit on #5124: a listener with no spoken Margin who asks for an episode's Listening Map met the hold and
    /// never got the card (on `main`, iOS asked at that tap). The map they asked for owes it, in words about the map, and
    /// shows when they reach for text too; a map prepared in the background stays quiet.
    func testAnEpisodeMapTheListenerAskedForOwesTheCardInItsOwnWords() {
        XCTAssertEqual(SpeechRecognitionAsk.CardWording.listeningMap.headline, "This episode's Listening Map needs speech recognition.")
        var asked = SpeechRecognitionAsk(storedAnswer: nil)
        asked.transcriptionHeld(.listenerEpisodeMap)
        XCTAssertTrue(asked.isOwed(access: .notDetermined))
        XCTAssertTrue(asked.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: false))
        XCTAssertEqual(asked.cardWording, .listeningMap)
        var background = SpeechRecognitionAsk(storedAnswer: nil)
        background.transcriptionHeld(.episodeMap)
        XCTAssertFalse(background.isOwed(access: .notDetermined))
    }

    /// Each purpose, by name: whether it owes the card and how it starts again after Allow. A new purpose must be added
    /// here, so its answer is a decision, not a default.
    func testEveryPurposeSaysWhetherItIsOwedAndHowItRetries() {
        let table: [HeldTranscription: (owed: Bool, retry: HeldTranscription.Retry)] = [
            .playerMargin: (true, .waitingList),
            .liveSessionMargin: (true, .liveSessionSweep),
            .watchMargin: (true, .liveSessionSweep),
            .shortcutMargin: (true, .liveSessionSweep),
            .friendPacketPlacement: (true, .callerRegisters),
            .episodeMap: (false, .callerRegisters),
            .listenerEpisodeMap: (true, .callerRegisters),
            .sourceWindow: (false, .callerRegisters),
            .publisherTextMap: (false, .callerRegisters),
            .justHeardPeek: (false, .none),
            .spokenNote: (true, .spokenNoteSweep),
        ]
        XCTAssertEqual(Set(table.keys), Set(HeldTranscription.allCases), "every purpose is in the table")
        for (purpose, expected) in table {
            XCTAssertEqual(purpose.makesAskOwed, expected.owed, purpose.rawValue)
            XCTAssertEqual(purpose.retry, expected.retry, purpose.rawValue)
        }
    }

    /// #4715, a decided no cleans up: a held source window keeps its heard audio and a held map says it waits, so a decided
    /// no must end each one (delete the audio, mark the Margin unavailable; the map's status stops waiting) instead of
    /// leaving them waiting forever. Allow and `drop` forget the decline.
    @MainActor
    func testADecidedNoRunsEachHeldPiecesDeclineAndAllowForgetsIt() {
        for decided in [SpeechRecognitionAccessState.denied, .restricted] {
            let retries = HeldTranscriptionRetries()
            var declined: [String] = []
            var retried = 0
            retries.hold(.sourceWindow, key: "s::m1") { retried += 1 }
            retries.whenDeclined(.sourceWindow, key: "s::m1") { declined.append("m1 first") }
            retries.whenDeclined(.sourceWindow, key: "s::m1") { declined.append("m1") }
            retries.hold(.episodeMap, key: "item") { retried += 1 }
            retries.whenDeclined(.episodeMap, key: "item") { declined.append("map") }
            XCTAssertEqual(retries.settle(access: .notDetermined), 0)
            XCTAssertEqual(declined, [], "undecided keeps waiting")
            XCTAssertEqual(retries.settle(access: decided), 0)
            XCTAssertEqual(declined, ["m1", "map"], "\(decided): each decline once, the latest for a key, oldest first")
            XCTAssertEqual(retried, 0)
            XCTAssertTrue(retries.isEmpty)
            XCTAssertEqual(retries.settle(access: decided), 0)
            XCTAssertEqual(declined.count, 2, "a decline runs once")
        }

        let allowed = HeldTranscriptionRetries()
        var declined = 0
        allowed.hold(.sourceWindow, key: "s::m1") {}
        allowed.whenDeclined(.sourceWindow, key: "s::m1") { declined += 1 }
        allowed.hold(.sourceWindow, key: "s::m2") {}
        allowed.whenDeclined(.sourceWindow, key: "s::m2") { declined += 1 }
        allowed.drop(.sourceWindow, keys: ["s::m2"])
        XCTAssertEqual(allowed.settle(access: .authorized), 1)
        XCTAssertEqual(allowed.settle(access: .denied), 0)
        XCTAssertEqual(declined, 0, "Allow and drop forget the decline")
    }

    /// #4715: a kill right after Allow must not lose held Margins or takes. Each sweep's held-across-launch record is
    /// forgotten only after that sweep ran to the end, never on Allow itself, and never for a sweep that could not run yet.
    @MainActor
    func testASweepsLaunchRecordIsForgottenOnlyAfterTheSweepRanToTheEnd() async {
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (gate, opens) = AsyncStream<Void>.makeStream()
        var forgotten: [String] = []
        let retries = HeldTranscriptionRetries(
            liveSessionSweep: {
                startedSignal.yield()
                for await _ in gate { break }
                return true
            },
            spokenNoteSweep: { false },
            sweepFinished: { forgotten.append($0) }
        )
        retries.reported(.liveSessionMargin)
        retries.reported(.spokenNote)
        XCTAssertEqual(retries.settle(access: .authorized), 2)
        for await _ in started { break }
        XCTAssertEqual(forgotten, [], "the live-session sweep is still running")
        opens.yield()
        await retries.sweepsEnded()
        XCTAssertEqual(forgotten, [SpeechRecognitionAsk.liveSessionMarginHeldKey], "the note sweep could not run yet")
    }

    /// A hold reported while its sweep still runs starts the sweep again on the next Allow; the first run ending must
    /// not forget the record the second run still needs.
    @MainActor
    func testAnOlderSweepEndingLeavesTheRecordForTheNewerRun() async {
        var gates: [AsyncStream<Void>.Continuation] = []
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        var forgotten: [String] = []
        let retries = HeldTranscriptionRetries(
            liveSessionSweep: {
                let (gate, opens) = AsyncStream<Void>.makeStream()
                gates.append(opens)
                startedSignal.yield()
                for await _ in gate { break }
                return true
            },
            spokenNoteSweep: { true },
            sweepFinished: { forgotten.append($0) }
        )
        var runs = started.makeAsyncIterator()
        retries.reported(.watchMargin)
        retries.settle(access: .authorized)
        let olderRun = retries.runningSweeps.last
        _ = await runs.next()
        retries.reported(.shortcutMargin)
        retries.settle(access: .authorized)
        _ = await runs.next()
        gates[0].yield()
        await olderRun?.value
        XCTAssertEqual(retries.runningSweeps.count, 1, "the older run ended")
        XCTAssertEqual(forgotten, [], "the newer run still needs the record")
        gates[1].yield()
        await retries.sweepsEnded()
        XCTAssertEqual(forgotten, [SpeechRecognitionAsk.liveSessionMarginHeldKey])
    }

    /// The sink registers the live-session sweep itself for a live-session, Watch or Shortcut Margin, once however many
    /// were held, so a `try?` at the caller loses none of them. Other purposes register nothing here.
    @MainActor
    func testAHeldLiveSessionWatchOrShortcutMarginRegistersOneSweep() {
        var sweeps = 0
        let retries = HeldTranscriptionRetries(liveSessionSweep: { sweeps += 1 })
        for purpose in HeldTranscription.allCases where purpose.retry != .liveSessionSweep && purpose.retry != .spokenNoteSweep {
            retries.reported(purpose)
        }
        XCTAssertTrue(retries.isEmpty, "the caller or the waiting list retries the rest")
        retries.reported(.liveSessionMargin)
        retries.reported(.watchMargin)
        retries.reported(.shortcutMargin)
        XCTAssertEqual(retries.settle(access: .notDetermined), 0)
        XCTAssertEqual(sweeps, 0)
        XCTAssertEqual(retries.settle(access: .authorized), 1)
        XCTAssertEqual(sweeps, 1, "one sweep covers every held live-session Margin")
        retries.reported(.watchMargin)
        XCTAssertEqual(retries.settle(access: .denied), 0)
        XCTAssertEqual(sweeps, 1, "a decided no drops it")
    }

    /// Director's Default taken on #4715, 2026-11-23: the listener's own recordings make the card due. A listener whose
    /// first recording is a spoken note (the Add source tile), with no spoken Margin anywhere, is owed the card in the
    /// existing Margins words once the note's take meets the hold.
    func testAListenerWhoseFirstRecordingIsASpokenNoteIsOwedTheCardInTheMarginsWords() {
        var ask = SpeechRecognitionAsk(storedAnswer: nil, hasSavedSpokenMargin: false)
        XCTAssertFalse(ask.isOwed(access: .notDetermined), "nothing recorded yet")
        ask.transcriptionHeld(.spokenNote)
        XCTAssertTrue(ask.isOwed(access: .notDetermined), "a held spoken note is the listener's own recording")
        XCTAssertEqual(ask.cardWording, .margins)
        XCTAssertEqual(ask.cardWording.headline, "Want your Margins as text too?")
        XCTAssertTrue(ask.cardDue(at: .reachedForText, access: .notDetermined, shownThisLaunchForReAsk: false))
    }

    /// A held spoken note registers one spoken-note sweep, however many takes were held, and no live-session sweep; the
    /// sweep runs once on Allow and is dropped on a no.
    @MainActor
    func testAHeldSpokenNoteRegistersOneSpokenNoteSweep() {
        var noteSweeps = 0
        var liveSweeps = 0
        let retries = HeldTranscriptionRetries(liveSessionSweep: { liveSweeps += 1 }, spokenNoteSweep: { noteSweeps += 1 })
        retries.reported(.spokenNote)
        retries.reported(.spokenNote)
        XCTAssertEqual(retries.heldKinds, [.spokenNote])
        XCTAssertEqual(retries.settle(access: .notDetermined), 0)
        XCTAssertEqual(retries.settle(access: .authorized), 1)
        XCTAssertEqual(noteSweeps, 1, "one sweep covers every held take")
        XCTAssertEqual(liveSweeps, 0)
        retries.reported(.spokenNote)
        XCTAssertEqual(retries.settle(access: .denied), 0)
        XCTAssertEqual(noteSweeps, 1, "a decided no drops it")
    }

    /// A held sweep is carried into the next launch under its own key, one purpose per key, so a relaunch owes the card
    /// again and sweeps after Allow: the live sessions' Margins and the spoken notes, each once.
    func testEachSweepIsCarriedAcrossALaunchUnderItsOwnKey() {
        let carried = HeldTranscription.heldAcrossLaunch
        XCTAssertEqual(carried.map(\.key), [SpeechRecognitionAsk.liveSessionMarginHeldKey, SpeechRecognitionAsk.spokenNoteHeldKey])
        XCTAssertEqual(carried.map(\.purpose), [.liveSessionMargin, .spokenNote])
        for (_, purpose) in carried {
            var ask = SpeechRecognitionAsk(storedAnswer: nil)
            ask.transcriptionHeld(purpose)
            XCTAssertTrue(ask.isOwed(access: .notDetermined), purpose.rawValue)
            XCTAssertEqual(ask.cardWording, .margins, purpose.rawValue)
        }
        XCTAssertNil(HeldTranscription.Retry.waitingList.heldAcrossLaunchKey)
        XCTAssertNil(HeldTranscription.Retry.callerRegisters.heldAcrossLaunchKey)
        XCTAssertNil(HeldTranscription.Retry.none.heldAcrossLaunchKey)
    }

    /// Every held path retries after Allow, whatever bookkeeping it kept (round 1 retried a friend's packet only when
    /// `requestedURL` was set). A decided no drops them; undecided keeps them; each kind and key is held once.
    @MainActor
    func testHeldTranscriptionsRetryOnAllowAndDropOnANo() {
        var ran: [String] = []
        let retries = HeldTranscriptionRetries()
        retries.hold(.friendPacketPlacement, key: "ep-1") { ran.append("friend-ep-1-old") }
        retries.hold(.episodeMap, key: "ep-1") { ran.append("map-ep-1") }
        retries.hold(.friendPacketPlacement, key: "ep-1") { ran.append("friend-ep-1") }
        retries.hold(.sourceWindow, key: "s::m") { ran.append("window-s::m") }
        retries.hold(.publisherTextMap, key: "article") { ran.append("publisher-article") }
        XCTAssertEqual(retries.heldKinds, [.friendPacketPlacement, .episodeMap, .sourceWindow, .publisherTextMap])

        XCTAssertEqual(retries.settle(access: .notDetermined), 0)
        XCTAssertEqual(ran, [], "undecided: nothing runs and nothing is dropped")
        retries.drop(.sourceWindow, keys: ["s::m"])
        XCTAssertEqual(retries.settle(access: .authorized), 3)
        XCTAssertEqual(ran, ["friend-ep-1", "map-ep-1", "publisher-article"], "oldest first, the latest retry kept")
        XCTAssertTrue(retries.isEmpty)
        XCTAssertEqual(retries.settle(access: .authorized), 0, "each runs once")

        for no in [SpeechRecognitionAccessState.denied, .restricted] {
            retries.hold(.friendPacketPlacement, key: "ep-2") { ran.append("never") }
            XCTAssertEqual(retries.settle(access: no), 0)
            XCTAssertTrue(retries.isEmpty, "\(no) drops the held work")
        }
        XCTAssertFalse(ran.contains("never"))
    }
}
