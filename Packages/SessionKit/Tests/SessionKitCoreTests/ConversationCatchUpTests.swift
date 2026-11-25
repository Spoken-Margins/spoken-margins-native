import XCTest
@testable import SessionKit

/// Catch-up (#4785): on an item the listener finished, a new reply to one of their own Margins gets the big button,
/// plays only what is new, pauses after it and ends on a card that says no answer is owed.
final class ConversationCatchUpTests: XCTestCase {
    private typealias Waiting = ItemListeningChoices.WaitingMargin

    private func reply(_ seconds: Int = 40, from name: String = "Cole", parent: String = "mine-1") -> Waiting {
        Waiting(senderName: name, audioDurationMs: seconds * 1_000, transcript: "", replyToYouParentId: parent)
    }

    private func newMargin(_ seconds: Int = 40, from name: String = "Cole") -> Waiting {
        Waiting(senderName: name, audioDurationMs: seconds * 1_000, transcript: "")
    }

    /// A reply whose parent is not on this phone, or is a friend's: `waitingMargin` gives it no own parent.
    private func replyNotToYou(from name: String = "Cole") -> Waiting {
        Waiting(senderName: name, audioDurationMs: 40_000, transcript: "", replyToYouParentId: nil, parentMissing: true)
    }

    // MARK: The rule

    func testCatchUpNeedsAFinishedItemAndADirectReplyToYourOwnMargin() {
        struct Row { let name: String; let finished: Bool; let waiting: [Waiting]; let expected: Bool }
        let rows = [
            Row(name: "finished, a reply to you", finished: true, waiting: [reply()], expected: true),
            Row(name: "finished, two replies to one Margin", finished: true, waiting: [reply(), reply()], expected: true),
            Row(name: "finished, mixed", finished: true, waiting: [reply(), newMargin()], expected: true),
            Row(name: "finished, a first packet", finished: true, waiting: [newMargin(), newMargin()], expected: false),
            Row(name: "finished, a reply whose parent is missing", finished: true, waiting: [replyNotToYou()], expected: false),
            Row(name: "not finished, a reply to you", finished: false, waiting: [reply()], expected: false),
            Row(name: "finished, nothing new", finished: true, waiting: [], expected: false),
        ]
        for row in rows {
            XCTAssertEqual(ConversationCatchUp.make(isFinished: row.finished, waiting: row.waiting) != nil, row.expected, row.name)
        }
    }

    func testAShareOfOrdinaryMarginsIsNeverCatchUpFromTheLibraryRowsEntries() {
        let layer = ImportedCommentaryLayer(
            id: "ana", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: "Ana", importedAt: Date(timeIntervalSince1970: 1), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false)
        let record = ImportedCommentaryInterjection(
            id: "m1", layerId: "ana", packageScopedId: "m1", createdAt: Date(timeIntervalSince1970: 1),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/m1.m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 60_000, confidence: 1))
        let entries = SharedMarginReview.entries(layers: [layer], records: ["ana": [record]], ownMargins: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(ConversationCatchUp.make(isFinished: true, entries: entries))
    }

    func testTheWords() throws {
        struct Row {
            let name: String; let waiting: [Waiting]
            let big: String; let offerTitle: String; let offerButton: String
        }
        let rows = [
            Row(name: "one reply from Cole", waiting: [reply()], big: "Hear Cole's replies · 1 min",
                offerTitle: "New replies to hear", offerButton: "Hear Cole's replies"),
            Row(name: "mixed from Cole", waiting: [reply(), newMargin()], big: "Hear Cole's new Margins · 2 min",
                offerTitle: "New Margins to hear", offerButton: "Hear Cole's new Margins"),
            Row(name: "replies from two people", waiting: [reply(from: "Cole"), reply(from: "Ana")],
                big: "Hear the replies · 2 min", offerTitle: "New replies to hear", offerButton: "Hear the replies"),
            Row(name: "mixed, unnamed", waiting: [reply(from: " "), newMargin(from: "")],
                big: "Hear the new Margins · 2 min", offerTitle: "New Margins to hear", offerButton: "Hear the new Margins"),
        ]
        for row in rows {
            let catchUp = try XCTUnwrap(ConversationCatchUp.make(isFinished: true, waiting: row.waiting), row.name)
            XCTAssertEqual(catchUp.bigButtonTitle(minutes: catchUp.minutes()), row.big, row.name)
            XCTAssertEqual(catchUp.offerTitle, row.offerTitle, row.name)
            XCTAssertEqual(catchUp.offerFirstButton, row.offerButton, row.name)
        }
    }

    /// The minutes add each own parent Margin the run plays before its reply: 20 s lead-in + 40 s reply is one minute,
    /// and a 90 s parent makes it two and a half, which rounds to three.
    func testTheMinutesCountTheOwnParentsTheRunPlays() throws {
        let catchUp = try XCTUnwrap(ConversationCatchUp.make(isFinished: true, waiting: [reply(40)]))
        XCTAssertEqual(catchUp.minutes(), 1)
        XCTAssertEqual(catchUp.minutes(ownParentDurationsMs: [90_000]), 3, "20 + 40 + 90 s = 2.5 min, rounded")
        XCTAssertEqual(catchUp.minutes(ownParentDurationsMs: [-5]), 1, "a broken length never subtracts")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([reply(40)]), 1, "the default is unchanged")
    }

    func testOwnParentLengthsCountEachSpokenParentOnceAndSkipWrittenOrMissingOnes() throws {
        func own(_ id: String, words: Int, voice: Bool = true) -> Interjection {
            Interjection(
                id: id, itemId: "item", sessionId: "s", targetType: .item, targetId: "item", createdAt: Date(timeIntervalSince1970: 1),
                roughPercent: 10,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000),
                audioPath: voice ? "Interjections/\(id).m4a" : nil, audioStatus: "ready", transcriptionStatus: "complete",
                transcript: Array(repeating: "word", count: words).joined(separator: " "), cleanedTranscript: nil, displayText: nil,
                status: "active")
        }
        // The parent key is the one `SharedMarginReview` and `ItemListeningChoices` hand over: `Interjection.sessionScopedId`
        // (#5133), never the bare id, which another listening pass of the same item can reuse.
        func key(_ id: String, session: String = "s") -> String { Interjection.sessionScopedId(sessionId: session, id: id) }
        let catchUp = try XCTUnwrap(ConversationCatchUp.make(
            isFinished: true,
            waiting: [reply(parent: key("spoken")), reply(parent: key("spoken")), reply(parent: key("written")), reply(parent: key("gone")),
                      reply(parent: key("elsewhere")), reply(parent: key("spoken", session: "other-pass"))]))
        let mine = [own("spoken", words: 100), own("written", words: 50, voice: false), own("gone", words: 10)]
        XCTAssertEqual(catchUp.ownParentLengthsMs(ownMargins: mine, hasVoice: { $0.id != "gone" }), [40_000],
                       "one spoken parent with its file, counted once; written, missing-file, unknown and other-pass parents left out")
    }

    // MARK: The item screen's buttons

    func testCatchUpOutranksEveryOtherStateOnTheItemScreen() throws {
        let waiting = [reply(40)]
        let catchUp = try XCTUnwrap(ConversationCatchUp.make(isFinished: true, waiting: waiting))
        for (behind, atEnd) in [([], false), (waiting, true), (waiting, false)] {
            let choices = ItemListeningChoices(
                unheardFriendMargins: waiting, marginsBehindPlace: behind, placeIsAtEnd: atEnd, hasFinishedSession: true,
                hasContinuationSession: true, isPreparingAudio: false, catchUp: catchUp)
            XCTAssertEqual(choices.primaryTitle, "Hear Cole's replies · 1 min")
            XCTAssertEqual(choices.primaryAction, .reviewNewMargins(thenContinue: false))
            XCTAssertEqual(choices.secondaryTitle, "Play from the start")
            XCTAssertEqual(choices.secondaryAction, .startFromBeginning)
            XCTAssertNil(choices.marginsOnlyTitle, "the second button is not a Skip to")
        }
        let relisten = ItemListeningChoices(
            unheardFriendMargins: waiting, hasFinishedSession: false, hasContinuationSession: true, isPreparingAudio: false,
            catchUp: catchUp, resumesShortOfEnd: true, ownParentDurationsMs: [90_000])
        XCTAssertEqual(relisten.primaryTitle, "Hear Cole's replies · 3 min")
        XCTAssertEqual(relisten.secondaryTitle, "Continue")
        XCTAssertEqual(relisten.secondaryAction, .play)
        XCTAssertEqual(
            relisten.primaryAccessibilityLabel,
            "Hear Cole's replies, 1 reply to your Margin, about 3 minutes. Pauses after the last one.")
    }

    func testWithNoCatchUpTheButtonsAreTodays() {
        let waiting = [reply(40)]
        let today = ItemListeningChoices(
            unheardFriendMargins: waiting, hasFinishedSession: true, hasContinuationSession: false, isPreparingAudio: false)
        XCTAssertEqual(today.primaryTitle, "Play")
        XCTAssertEqual(today.secondaryTitle, "Skip to Cole's reply · 1 min")
    }

    // MARK: Where the run starts

    private func session(_ id: String, percent: Int, finished: Bool = false, updated: TimeInterval = 1) -> Session {
        Session(
            id: id, itemId: "item", updatedAt: Date(timeIntervalSince1970: updated), status: finished ? "finished" : "in_progress",
            phase: finished ? .finished : .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: 0, mediaTimeMs: 600_000), completionPercent: percent, playbackRate: 1)
    }

    func testACatchUpRunNeverMovesAFinishedSessionOrOneAtTheEnd() {
        let rows: [(String, [Session], PlayRule.StartAction)] = [
            ("no session (finished by the mark)", [], .startNew),
            ("a finished session at 100%", [session("done", percent: 100, finished: true)], .startNew),
            ("a session at 100%", [session("end", percent: 100)], .startNew),
            ("a session at 99%", [session("almost", percent: 99)], .startNew),
            ("a re-listen at 40% after a finished pass",
             [session("done", percent: 100, finished: true, updated: 1), session("again", percent: 40, updated: 2)],
             .resume(session("again", percent: 40, updated: 2))),
        ]
        for (name, sessions, expected) in rows {
            XCTAssertEqual(PlayRule.catchUpStart(sessions: sessions, addedAgainAt: nil), expected, name)
        }
        XCTAssertEqual(
            PlayRule.startAction(sessions: [session("almost", percent: 99)], addedAgainAt: nil),
            .resume(session("almost", percent: 99)), "plain Play still resumes at 99%: only the catch-up start differs")
    }

    // MARK: The run's end

    private func anchor(_ id: String, _ ms: Int) -> MarginMomentAnchor { MarginMomentAnchor(marginId: id, mediaTimeMs: ms) }

    func testARunThatEndsPausedNeverGoesBackOrPlaysOn() throws {
        for returnTo: Int? in [nil, 100_000, 900_000] {
            var sequence = try XCTUnwrap(MarginMomentSequence(
                itemId: "ep", reviewing: [anchor("a", 300_000)], returnToMediaTimeMs: returnTo, resumesAtEnd: false, endsPaused: true))
            XCTAssertEqual(sequence.progressed(from: 299_800, to: 300_100)?.marginId, "a")
            XCTAssertEqual(
                sequence.marginFinished(sourceAtMediaTimeMs: 300_100), .reviewDone(returnToMediaTimeMs: nil, resumes: false),
                "return place \(String(describing: returnTo))")
            XCTAssertEqual(sequence.phase, .listening)
        }
        let stopped = try XCTUnwrap(MarginMomentSequence(
            itemId: "ep", reviewing: [anchor("a", 300_000)], returnToMediaTimeMs: 100_000, endsPaused: true))
        XCTAssertEqual(stopped.placeToReturnToWhenStopped(sourceAtMediaTimeMs: 280_000), 100_000, "Stop still gives the place back")
        var ordinary = try XCTUnwrap(MarginMomentSequence(itemId: "ep", reviewing: [anchor("a", 300_000)]))
        XCTAssertEqual(ordinary.progressed(from: 299_800, to: 300_100)?.marginId, "a")
        XCTAssertEqual(ordinary.marginFinished(sourceAtMediaTimeMs: 300_100), .reviewDone(returnToMediaTimeMs: nil, resumes: true),
                       "the default review still plays on")
    }

    // MARK: The run and its card

    private func makeRun(sender: String? = "Cole", replies: Int = 1, allReplies: Bool = true, noun: SourceNoun = .episode) -> CatchUpRun {
        CatchUpRun(
            itemId: "item", friendMarginIds: ["ana::r1"], senderName: sender, replyCount: replies, allReplies: allReplies,
            noun: noun, title: "The Long Walk")
    }

    func testTheCardShowsOnlyAfterTheNaturalEnd() {
        var running = makeRun()
        XCTAssertNil(running.card)
        for event: CatchUpRun.Event in [.play, .scrub, .recordingStarted, .dismissed] {
            running.handle(event)
            XCTAssertTrue(running.isRunning, "\(event) mid-run belongs to the review")
        }
        running.handle(.completed(stillNew: 0))
        XCTAssertNotNil(running.card)

        for event: CatchUpRun.Event in [.stopped, .otherItemOpened] {
            var early = makeRun()
            early.handle(event)
            XCTAssertEqual(early.state, .stopped, "\(event)")
            early.handle(.completed(stillNew: 0))
            XCTAssertNil(early.card, "a stopped run never shows the card")
        }
    }

    func testEveryWayTheCardGoes() {
        for event: CatchUpRun.Event in [.dismissed, .play, .scrub, .recordingStarted, .otherItemOpened] {
            var ended = makeRun()
            ended.handle(.completed(stillNew: 0))
            ended.handle(event)
            XCTAssertEqual(ended.state, .dismissed, "\(event)")
            XCTAssertNil(ended.card, "\(event)")
        }
        var ended = makeRun()
        ended.handle(.completed(stillNew: 0))
        ended.handle(.stopped)
        XCTAssertNotNil(ended.card, "a later Stop has nothing to stop")
    }

    /// Lock Screen, AirPods, CarPlay, Watch and the compact buttons arrive as compact commands. Each one that moves the
    /// source, plays it or starts a recording puts the card away, as the app's own buttons do (#4785 audit).
    func testEveryTransportCommandThatPlaysMovesOrRecordsPutsTheCardAway() {
        for command in CompactControlCommand.allCases {
            for playing in [false, true] {
                var ended = makeRun()
                ended.handle(.completed(stillNew: 0))
                if let event = CatchUpRun.Event.event(for: command, sourceIsPlaying: playing) { ended.handle(event) }
                let goes: Bool
                switch command {
                case .play, .skipBack, .skipForward, .skimBackward, .skimForward, .seekToMediaTime, .jumpToChapter,
                     .beginInterjection:
                    goes = true
                case .togglePlayPause:
                    goes = !playing
                case .pause, .setPlaybackRate, .finishInterjection, .cancelInterjection, .generateInterjectionSummary,
                     .submitFollowup:
                    goes = false
                }
                XCTAssertEqual(ended.card == nil, goes, "\(command), playing: \(playing)")
                XCTAssertEqual(command.movesPlaybackPosition && ended.card != nil, false, "every move is a scrub: \(command)")
            }
        }
        var running = makeRun()
        for command in CompactControlCommand.allCases {
            if let event = CatchUpRun.Event.event(for: command, sourceIsPlaying: false) { running.handle(event) }
        }
        XCTAssertTrue(running.isRunning, "mid-run, transport belongs to the review")
    }

    func testTheCaughtUpCardsWords() throws {
        struct Row {
            let name: String; let run: CatchUpRun; let stillNew: Int
            let headline: String; let detail: String; let buttons: [String]
        }
        let rows = [
            Row(name: "all heard, Cole", run: makeRun(), stillNew: 0, headline: "You're caught up with Cole",
                detail: "That's everything new on this episode. You don't need to answer.", buttons: ["Let Cole know", "Dismiss"]),
            Row(name: "all heard, several", run: makeRun(sender: nil), stillNew: 0, headline: "You're caught up",
                detail: "That's everything new on this episode. You don't need to answer.", buttons: ["Let them know", "Dismiss"]),
            Row(name: "all heard, an article", run: makeRun(noun: .article), stillNew: 0, headline: "You're caught up with Cole",
                detail: "That's everything new on this article. You don't need to answer.", buttons: ["Let Cole know", "Dismiss"]),
            Row(name: "a long name", run: makeRun(sender: "Alexandria Bartholomew-Featherstonehaugh"), stillNew: 0,
                headline: "You're caught up with Alexandria Bartholomew-Featherstonehaugh",
                detail: "That's everything new on this episode. You don't need to answer.", buttons: ["Let Alexandria know", "Dismiss"]),
            Row(name: "one left new", run: makeRun(), stillNew: 1, headline: "Cole's replies have played",
                detail: "1 stays marked new.", buttons: ["Dismiss"]),
            Row(name: "two left new, mixed, unnamed", run: makeRun(sender: nil, allReplies: false), stillNew: 2,
                headline: "The new Margins have played", detail: "2 stay marked new.", buttons: ["Dismiss"]),
        ]
        for row in rows {
            var run = row.run
            run.handle(.completed(stillNew: row.stillNew))
            let card = try XCTUnwrap(run.card, row.name)
            XCTAssertEqual(card.headline, row.headline, row.name)
            XCTAssertEqual(card.detail, row.detail, row.name)
            XCTAssertEqual(card.actions.map(\.title), row.buttons, row.name)
            XCTAssertFalse(card.detail.contains("add a Margin"), "never the homework ending: \(row.name)")
        }
    }

    func testTheCardsJobs() throws {
        var heard = makeRun()
        heard.handle(.completed(stillNew: 0))
        let card = try XCTUnwrap(heard.card)
        XCTAssertEqual(card.actions.map(\.job), [PinnedMarginCard.Action.Job.letFriendKnow, .dismissCaughtUp])
        XCTAssertEqual(card.actions.map(\.prominence), [PinnedMarginCard.Action.Prominence.secondary, .quiet])
        XCTAssertEqual(card.actions.map(\.hint), ["Opens the share sheet with a short message.", "Hides this card."])
    }

    func testTheShareLine() {
        XCTAssertEqual(makeRun(replies: 1).shareText, "Heard your reply on \u{201C}The Long Walk\u{201D}.")
        XCTAssertEqual(makeRun(replies: 2).shareText, "Heard your replies on \u{201C}The Long Walk\u{201D}.")
        XCTAssertEqual(makeRun(replies: 0, allReplies: false).shareText, "Heard your new Margins on \u{201C}The Long Walk\u{201D}.")
    }

    func testTheRunTakesItsWordsFromTheCatchUp() throws {
        let catchUp = try XCTUnwrap(ConversationCatchUp.make(isFinished: true, waiting: [reply(), reply(parent: "mine-2"), newMargin()]))
        let run = CatchUpRun(itemId: "item", catchUp: catchUp, friendMarginIds: ["a", "b", "c"], noun: .episode, title: "T")
        XCTAssertEqual(run.senderName, "Cole")
        XCTAssertEqual(run.replyCount, 2)
        XCTAssertFalse(run.allReplies)
    }
}
