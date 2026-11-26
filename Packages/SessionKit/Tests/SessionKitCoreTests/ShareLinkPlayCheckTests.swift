import SessionKit
import XCTest

/// #4454: what the sender's background play check says, from the web page's messages to the line under Share link.
final class ShareLinkPlayCheckTests: XCTestCase {
    private typealias Check = ShareLinkPlayCheck
    private let online = Check.Network(isOnline: true, isLowDataMode: false)

    // MARK: Reading the page's messages (the words of Web/src/app/play-check.ts)

    func testEveryMessageTheWebPageSendsIsRead() {
        XCTAssertEqual(Check.Message(body: ["type": "started"]), .started)
        XCTAssertEqual(Check.Message(body: ["type": "verdict", "verdict": "plays"]), .plays)
        XCTAssertEqual(Check.Message(body: ["type": "verdict", "verdict": "unverified", "why": "post-voice"]), .unverifiedPostVoice)
        for reason in ["article", "no-episode-audio", "paid-post", "no-post-voice", "audio-refused", "audio-format"] {
            let expected = Check.Reason(rawValue: reason)!
            XCTAssertEqual(Check.Message(body: ["type": "verdict", "verdict": "cannot", "reason": reason]), .cannot(expected), reason)
        }
        XCTAssertEqual(Check.Message(body: ["type": "failed", "reason": "link-broken"]), .linkDidNotOpen(.linkBroken))
        XCTAssertEqual(Check.Message(body: ["type": "failed", "reason": "links-off"]), .linkDidNotOpen(.linksOff))
        XCTAssertEqual(Check.Message(body: ["type": "failed", "reason": "offline"]), .couldNotReach(offline: true))
        XCTAssertEqual(Check.Message(body: ["type": "failed", "reason": "server"]), .couldNotReach(offline: false))
    }

    func testAnythingElseIsIgnoredNeverGuessedAt() {
        let bodies: [Any] = [
            "started", 3, [String: Any](), ["type": "nope"], ["type": "verdict"], ["type": "verdict", "verdict": "maybe"],
            ["type": "verdict", "verdict": "cannot"], ["type": "verdict", "verdict": "cannot", "reason": "weather"],
            // A broken or switched-off link is a failure to open, never a verdict about playing.
            ["type": "verdict", "verdict": "cannot", "reason": "link-broken"],
            ["type": "verdict", "verdict": "cannot", "reason": "links-off"],
            ["type": "verdict", "verdict": "unverified"], ["type": "verdict", "verdict": "unverified", "why": "else"],
            ["type": "failed"], ["type": "failed", "reason": "weather"], ["type": 4], ["verdict": "plays"]
        ]
        for body in bodies { XCTAssertNil(Check.Message(body: body), "\(body)") }
    }

    // MARK: Words

    func testEveryReasonHasAHeadingAndARemedyAndNoneUsesColourAlone() {
        for reason in Check.Reason.allCases {
            let words = Check.words(for: reason)
            XCTAssertFalse(words.heading.isEmpty, "\(reason)")
            XCTAssertFalse(words.remedy.isEmpty, "\(reason)")
            let line = Check.line(for: .problem(reason))
            XCTAssertEqual(line?.kind, .warning)
            XCTAssertEqual(line?.heading, words.heading)
            XCTAssertEqual(line?.remedy, words.remedy)
            XCTAssertEqual(line?.accessibilityLabel, "Warning. \(words.heading) \(words.remedy)")
            XCTAssertEqual(line?.isAnnounced, true)
        }
        // The friend's browser now plays each Margin after its words (#5265): the line says what they get, not a failure.
        XCTAssertEqual(Check.words(for: .article).heading, "Your friend's browser plays your Margins on their own, not in place.")
        XCTAssertEqual(
            Check.words(for: .article).remedy,
            "Each one plays after the words just before it. To hear them in place, they need Spoken Margins on iPhone.")
        XCTAssertEqual(Check.words(for: .noEpisodeAudio).heading, "Your friend's browser plays your Margins without the episode.")
        XCTAssertEqual(
            Check.words(for: .noEpisodeAudio).remedy,
            "It has no public audio link. If the show has a public feed, add the episode from there and share again.")
        XCTAssertEqual(Check.words(for: .linkBroken).remedy, "Make a new link, or tap Send as a file.")
        // #5264: the browser shows only timed Margin words for a post with no voice.
        // The article line is #5265's (#5355): its listen-here card shows every Margin.
        XCTAssertEqual(Check.words(for: .noPostVoice).remedy, "To hear it read aloud with your Margins, they need Spoken Margins on iPhone.")
        for reason in Check.Reason.allCases where reason != .article {
            XCTAssertFalse(Check.words(for: reason).remedy.contains("They'll see your Margins' words"), "\(reason)")
        }
    }

    func testOnlyAProblemIsAWarningOrAnnouncedOrReachesTheBanner() {
        let others: [Check.Outcome] = [
            .checking, .plays, .gone, .notChecked(.offline), .notChecked(.lowDataMode), .notChecked(.didNotFinish),
            .notChecked(.postVoiceNotLookedUp)
        ]
        for outcome in others {
            XCTAssertNotEqual(Check.line(for: outcome)?.kind, .warning, "\(outcome)")
            XCTAssertEqual(Check.line(for: outcome)?.isAnnounced ?? false, false, "\(outcome)")
            XCTAssertNil(Check.bannerText(for: outcome, title: "T"), "\(outcome)")
        }
        XCTAssertNil(Check.line(for: .gone))
        XCTAssertEqual(Check.line(for: .checking)?.heading, "Checking it plays in a browser…")
        XCTAssertEqual(Check.line(for: .plays)?.heading, "Checked: it plays in a browser.")
        XCTAssertEqual(Check.line(for: .notChecked(.offline))?.heading, "Not checked: you're offline.")
        XCTAssertEqual(Check.line(for: .notChecked(.lowDataMode))?.heading, "Not checked: Low Data Mode is on.")
        XCTAssertEqual(Check.line(for: .notChecked(.didNotFinish))?.heading, "Not checked: the check didn't finish.")
        XCTAssertEqual(
            Check.bannerText(for: .problem(.noEpisodeAudio), title: "Episode 4"),
            "Your link for \u{201C}Episode 4\u{201D}: Your friend's browser plays your Margins without the episode.")
    }

    // MARK: One check

    private func run(_ events: [Check.Event]) -> Check.Session {
        var session = Check.Session()
        for event in events { session.apply(event) }
        return session
    }

    func testAPlayingLinkEndsChecked() {
        XCTAssertEqual(run([.message(.started)]).outcome, .checking)
        XCTAssertEqual(run([.message(.started), .message(.plays)]).outcome, .plays)
    }

    func testAProblemEndsAsAProblemAndAFailureToOpenIsOneToo() {
        XCTAssertEqual(run([.message(.started), .message(.cannot(.article))]).outcome, .problem(.article))
        XCTAssertEqual(run([.message(.started), .message(.linkDidNotOpen(.linksOff))]).outcome, .problem(.linksOff))
        XCTAssertEqual(run([.message(.started), .message(.linkDidNotOpen(.linkBroken))]).outcome, .problem(.linkBroken))
    }

    func testEveryWayTheCheckCouldNotRunIsNotCheckedAndNeverAWarning() {
        XCTAssertEqual(run([.message(.started), .message(.couldNotReach(offline: true))]).outcome, .notChecked(.offline))
        XCTAssertEqual(run([.message(.started), .message(.couldNotReach(offline: false))]).outcome, .notChecked(.didNotFinish))
        XCTAssertEqual(run([.message(.started), .processEnded]).outcome, .notChecked(.didNotFinish))
        XCTAssertEqual(run([.message(.started), .enteredBackground]).outcome, .notChecked(.didNotFinish))
        XCTAssertEqual(run([.message(.started), .timedOut]).outcome, .notChecked(.didNotFinish))
        XCTAssertEqual(run([.processEnded]).outcome, .notChecked(.didNotFinish))
        XCTAssertEqual(run([.enteredBackground]).outcome, .notChecked(.didNotFinish))
        // A Substack post's voice can't be settled without a publisher read: honest, and never "Checked".
        XCTAssertEqual(run([.message(.started), .message(.unverifiedPostVoice)]).outcome, .notChecked(.postVoiceNotLookedUp))
    }

    func testAPageThatNeverSaysItStartedLeavesNoLine() {
        // A web app that predates the check: the line shows "Checking…" and then goes away, never a failure.
        let session = run([.timedOut])
        XCTAssertEqual(session.outcome, .gone)
        XCTAssertNil(Check.line(for: session.outcome))
    }

    func testTheFirstFinalOutcomeStands() {
        let events: [[Check.Event]] = [
            [.message(.started), .message(.plays), .timedOut],
            [.message(.started), .message(.plays), .message(.cannot(.article))],
            [.message(.started), .message(.plays), .enteredBackground, .processEnded]
        ]
        for sequence in events { XCTAssertEqual(run(sequence).outcome, .plays, "\(sequence)") }
        XCTAssertEqual(run([.message(.started), .message(.cannot(.article)), .message(.plays)]).outcome, .problem(.article))
        XCTAssertEqual(run([.timedOut, .message(.started), .message(.plays)]).outcome, .gone)
    }

    func testTheTimeLimitIsTwentyFiveSeconds() {
        XCTAssertEqual(Check.timeLimit, 25)
    }

    // MARK: Starting

    func testOfflineAndLowDataModeSkipTheCheckAndSayWhy() {
        XCTAssertNil(Check.skipReason(for: online))
        XCTAssertEqual(Check.skipReason(for: .init(isOnline: false, isLowDataMode: false)), .offline)
        XCTAssertEqual(Check.skipReason(for: .init(isOnline: true, isLowDataMode: true)), .lowDataMode)
        // Offline wins when both hold: Low Data Mode is no news to a phone with no connection.
        XCTAssertEqual(Check.skipReason(for: .init(isOnline: false, isLowDataMode: true)), .offline)
        XCTAssertEqual(Check.Session(skippedFor: .init(isOnline: false, isLowDataMode: false)).outcome, .notChecked(.offline))
        XCTAssertEqual(Check.Session(skippedFor: .init(isOnline: true, isLowDataMode: true)).outcome, .notChecked(.lowDataMode))
        XCTAssertEqual(Check.Session(skippedFor: online).outcome, .checking)
    }

    // MARK: Which link is checked

    func testTheFirstLinkStartsAtOnce() {
        var queue = Check.Queue()
        XCTAssertEqual(queue.request(linkID: "a", network: online), .start)
        XCTAssertEqual(queue.outcome(for: "a"), .checking)
    }

    func testANewerLinkWaitsBehindTheRunningCheckAndReplacesAnOlderWaitingOne() {
        var queue = Check.Queue()
        XCTAssertEqual(queue.request(linkID: "a", network: online), .start)
        XCTAssertEqual(queue.request(linkID: "b", network: online), .wait(replaced: nil))
        XCTAssertEqual(queue.request(linkID: "c", network: online), .wait(replaced: "b"))
        XCTAssertNil(queue.outcome(for: "b"), "a replaced link has no line")
        XCTAssertEqual(queue.running, "a")
        XCTAssertEqual(queue.waiting, "c")
        // The running check ends; the newest waiting link starts, and nothing is left waiting.
        XCTAssertEqual(queue.apply(.message(.plays), to: "a"), "c")
        XCTAssertEqual(queue.running, "c")
        XCTAssertNil(queue.waiting)
    }

    func testTheNextLinkStartsOnlyWhenTheRunningCheckEnds() {
        var queue = Check.Queue()
        _ = queue.request(linkID: "a", network: online)
        _ = queue.request(linkID: "b", network: online)
        XCTAssertNil(queue.apply(.message(.started), to: "a"), "a start is not an end")
        XCTAssertEqual(queue.apply(.message(.cannot(.article)), to: "a"), "b")
        XCTAssertEqual(queue.running, "b")
        XCTAssertNil(queue.waiting)
        XCTAssertEqual(queue.outcome(for: "a"), .problem(.article))
        XCTAssertNil(queue.apply(.timedOut, to: "b"))
        XCTAssertNil(queue.running)
        // With nothing running, the next link starts at once again.
        XCTAssertEqual(queue.request(linkID: "c", network: online), .start)
    }

    func testSharingTheSameLinkAgainChecksNothingAgain() {
        var queue = Check.Queue()
        XCTAssertEqual(queue.request(linkID: "a", network: online), .start)
        XCTAssertEqual(queue.request(linkID: "a", network: online), .alreadyKnown, "running")
        _ = queue.request(linkID: "b", network: online)
        XCTAssertEqual(queue.request(linkID: "b", network: online), .alreadyKnown, "waiting")
        _ = queue.apply(.message(.plays), to: "a")
        XCTAssertEqual(queue.request(linkID: "a", network: online), .alreadyKnown, "finished")
        XCTAssertEqual(queue.outcome(for: "a"), .plays)
    }

    func testOfflineOrLowDataModeNeverStartsACheckOrBlocksTheNextOne() {
        var queue = Check.Queue()
        XCTAssertEqual(queue.request(linkID: "a", network: .init(isOnline: false, isLowDataMode: false)), .alreadyKnown)
        XCTAssertEqual(queue.outcome(for: "a"), .notChecked(.offline))
        XCTAssertNil(queue.running)
        XCTAssertEqual(queue.request(linkID: "b", network: .init(isOnline: true, isLowDataMode: true)), .alreadyKnown)
        XCTAssertEqual(queue.outcome(for: "b"), .notChecked(.lowDataMode))
        XCTAssertEqual(queue.request(linkID: "c", network: online), .start)
        XCTAssertEqual(queue.request(linkID: "b", network: online), .wait(replaced: nil), "Low Data Mode off: b is checked next")
    }

    func testACheckThatCouldNotRunIsAskedForAgainButAResultIsNot() {
        var queue = Check.Queue()
        // Offline now, online later: the same link is checked then.
        XCTAssertEqual(queue.request(linkID: "a", network: .init(isOnline: false, isLowDataMode: false)), .alreadyKnown)
        XCTAssertEqual(queue.request(linkID: "a", network: online), .start)
        XCTAssertEqual(queue.outcome(for: "a"), .checking)
        // Out of time: asked for again on the next share.
        XCTAssertNil(queue.apply(.message(.started), to: "a"))
        XCTAssertNil(queue.apply(.timedOut, to: "a"))
        XCTAssertEqual(queue.outcome(for: "a"), .notChecked(.didNotFinish))
        XCTAssertEqual(queue.request(linkID: "a", network: online), .start)
        // A verdict, an unsettled post voice and a page with no check stay as they are.
        _ = queue.apply(.message(.started), to: "a")
        _ = queue.apply(.message(.unverifiedPostVoice), to: "a")
        XCTAssertEqual(queue.request(linkID: "a", network: online), .alreadyKnown)
        XCTAssertEqual(queue.request(linkID: "p", network: online), .start)
        _ = queue.apply(.message(.started), to: "p")
        _ = queue.apply(.message(.cannot(.article)), to: "p")
        XCTAssertEqual(queue.request(linkID: "p", network: online), .alreadyKnown)
        XCTAssertEqual(queue.outcome(for: "p"), .problem(.article))
        XCTAssertEqual(queue.request(linkID: "g", network: online), .start)
        _ = queue.apply(.timedOut, to: "g")
        XCTAssertEqual(queue.outcome(for: "g"), .gone)
        XCTAssertEqual(queue.request(linkID: "g", network: online), .alreadyKnown)
    }

    func testAnEventForAWaitingOrReplacedLinkChangesNothing() {
        var queue = Check.Queue()
        _ = queue.request(linkID: "a", network: online)
        _ = queue.request(linkID: "b", network: online)
        XCTAssertNil(queue.apply(.timedOut, to: "b"), "b is waiting, with no web view")
        XCTAssertEqual(queue.outcome(for: "b"), .checking)
        _ = queue.request(linkID: "c", network: online)
        XCTAssertNil(queue.apply(.message(.plays), to: "b"), "b was replaced")
        XCTAssertNil(queue.outcome(for: "b"))
        XCTAssertEqual(queue.apply(.message(.plays), to: "a"), "c")
        XCTAssertEqual(queue.running, "c")
    }

    func testGoingToTheBackgroundEndsTheRunningCheckAndTheWaitingOne() {
        var queue = Check.Queue()
        _ = queue.request(linkID: "a", network: online)
        _ = queue.apply(.message(.started), to: "a")
        _ = queue.request(linkID: "b", network: online)
        XCTAssertNil(queue.enteredBackground(), "nothing is left to start")
        XCTAssertEqual(queue.outcome(for: "a"), .notChecked(.didNotFinish))
        XCTAssertEqual(queue.outcome(for: "b"), .notChecked(.didNotFinish))
        XCTAssertNil(queue.running)
        XCTAssertNil(queue.waiting)
        var empty = Check.Queue()
        XCTAssertNil(empty.enteredBackground())
    }

    func testAnEventForAnUnknownLinkChangesNothing() {
        var queue = Check.Queue()
        _ = queue.request(linkID: "a", network: online)
        XCTAssertNil(queue.apply(.message(.plays), to: "zzz"))
        XCTAssertEqual(queue.running, "a")
        XCTAssertEqual(queue.outcome(for: "a"), .checking)
    }
}
