import Foundation
import SessionKitPersistence
import XCTest
@testable import SessionKit

/// #4099: where Play starts and whether it asks first, for every state a listener can be in. Each row is one state
/// and the outcome `main` gives today. Rows whose outcome the owner hasn't settled say so; they pin today's behaviour
/// so that changing it (#4125, #4101) is a visible edit to one row, not a side effect.
final class PlayRuleTests: XCTestCase {
    private let end = 1_800_000
    private let early = Date(timeIntervalSince1970: 1)

    // MARK: Fixtures

    private func session(
        _ id: String, status: String = "in_progress", phase: SessionPhase = .itemPlayback, percent: Int,
        mediaTimeMs: Int? = nil, updated: TimeInterval = 1
    ) -> Session {
        Session(
            id: id, itemId: "item", updatedAt: Date(timeIntervalSince1970: updated), status: status, phase: phase,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: 0, mediaTimeMs: mediaTimeMs), completionPercent: percent, playbackRate: 1)
    }

    private func finished(percent: Int = 100, updated: TimeInterval = 1) -> Session {
        session("done", status: "finished", phase: .finished, percent: percent, mediaTimeMs: end, updated: updated)
    }

    private func layer() -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "ana", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: end),
            displayLabel: "Ana", importedAt: early, sourceResolutionStatus: .resolved, isEnabled: true, isMuted: false)
    }

    private func record(_ id: String, at ms: Int, replyLinks: [MarginReplyLink]? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "ana", packageScopedId: id, createdAt: early,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 1),
            replyLinks: replyLinks)
    }

    /// Ana's Margins at 2:00, 10:00 and 25:00 of a 30-minute episode.
    private func margins(_ times: [Int] = [120_000, 600_000, 1_500_000], ownMargins: [Interjection] = []) -> [SharedMarginReview.Entry] {
        let records = times.enumerated().map { record("m\($0.offset)", at: $0.element) }
        return SharedMarginReview.entries(layers: [layer()], records: ["ana": records], ownMargins: ownMargins)
    }

    private func marginId(_ index: Int) -> String { SharedMarginReview.marginId(layerId: "ana", interjectionId: "m\(index)") }

    /// The row the Library draws for `sessions`, as `LibraryRowBuilder` builds it.
    private func row(_ sessions: [Session], completedByHand: Bool = false) throws -> LibraryItemRow {
        var item = Item(id: "item", title: "Episode", mediaType: "podcast", text: nil, externalReference: nil, status: "ready")
        if completedByHand { item.sourceCompletedAt = early }
        let snapshot = LibraryReadSnapshot(items: [item], sessions: sessions, manifests: [], jobs: [], downloads: [])
        let context = StartupAudioContext(
            hasAcceptedCurrentTerms: true, hasSupertonicVoice: true, suppressedItemIds: [], liveSpeechFallbackItemIds: [],
            failedItemIds: [], preparingItemId: nil, playingItemId: nil, renderSignature: nil, allowsRendering: true)
        return try XCTUnwrap(LibraryRowBuilder.rows(from: snapshot, context: context).first)
    }

    private func ask(_ indexes: [Int]) -> PlayRule.Outcome { .askFirst(marginsBehind: margins().filter { indexes.map(marginId).contains($0.marginId) }) }

    private func assertDecision(_ context: PlayRule.Context, _ expected: PlayRule.Outcome, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let outcome = PlayRule.decide(context)
        XCTAssertEqual(outcome, expected, name, file: file, line: line)
    }

    private func context(
        surface: PlayRule.Surface = .libraryRow, nowPlaying: PlayRule.NowPlaying? = nil, open sessions: [Session]? = nil,
        row: LibraryItemRow? = nil, margins newMargins: [SharedMarginReview.Entry]? = nil,
        declined: NewMarginsOfferMemory = NewMarginsOfferMemory()
    ) -> PlayRule.Context {
        PlayRule.Context(
            itemId: "item", surface: surface, nowPlaying: nowPlaying,
            openItem: sessions.map { PlayRule.OpenItem(id: "item", sessions: $0) }, libraryRow: row,
            newMargins: newMargins ?? margins(), declined: declined)
    }

    // MARK: Where the listener is

    func testNotStartedPlaysFromTheBeginningWhetherOrNotTheItemIsOpen() throws {
        assertDecision(context(open: []), .play(.beginning), "open, no session")
        assertDecision(context(row: try row([])), .play(.beginning), "not open, a row with no session")
        assertDecision(context(), .play(.beginning), "not open, the Library holds no row")
    }

    /// The Margin the listener is past is asked about; one ahead, or at the place, plays in place (#3059).
    func testAMarginAheadAtAndBehindThePlace() {
        let at = { (ms: Int) in self.context(open: [self.session("a", percent: 10, mediaTimeMs: ms)], margins: self.margins([120_000])) }
        assertDecision(at(60_000), .play(.savedPlace(mediaTimeMs: 60_000)), "Margin ahead: plays in place, no question")
        assertDecision(at(120_000), .play(.savedPlace(mediaTimeMs: 120_000)), "Margin exactly at the place: plays in place")
        assertDecision(at(120_001), .askFirst(marginsBehind: margins([120_000])), "Margin behind: asked, never skipped silently")
        assertDecision(at(720_000), .askFirst(marginsBehind: margins([120_000])), "Margin well behind")
    }

    func testOnlyTheMarginsBehindThePlaceAreAskedAbout() {
        assertDecision(context(open: [session("a", percent: 40, mediaTimeMs: 720_000)]), ask([0, 1]), "12:00 passes the first two")
        assertDecision(context(open: [session("a", percent: 5, mediaTimeMs: 60_000)]), .play(.savedPlace(mediaTimeMs: 60_000)), "all ahead")
    }

    /// Completion 98, 99, 99.9 (stored as 99: the engine truncates) and 100 on the open item and on the Library row.
    /// Anything under 100 resumes at its end, past every Margin; only 100 begins again.
    func testNearTheEndResumesPastEveryMarginAndOnlyTheEndBeginsAgain() throws {
        for percent in [98, 99] {
            let ms = end * percent / 100
            let sessions = [session("a", percent: percent, mediaTimeMs: ms)]
            assertDecision(context(open: sessions), ask([0, 1, 2]), "open item at \(percent)%")
            assertDecision(context(row: try row(sessions)), ask([0, 1, 2]), "Library row at \(percent)%: the row holds no place, so all are asked")
        }
        let atTheEndButUnfinished = [session("a", percent: 100, mediaTimeMs: end)]
        assertDecision(context(open: atTheEndButUnfinished), .play(.beginning), "100%: Play begins again")
        assertDecision(context(row: try row(atTheEndButUnfinished)), .play(.beginning), "100% on the row")
    }

    func testAFinishedSessionReplaysFromTheStart() throws {
        assertDecision(context(open: [finished()]), .play(.beginning), "open item")
        assertDecision(context(row: try row([finished()])), .play(.beginning), "Library row")
    }

    func testAnOlderFinishedSessionDoesNotHideANewerOneInProgress() throws {
        let sessions = [finished(updated: 1), session("new", percent: 90, mediaTimeMs: 1_600_000, updated: 2)]
        assertDecision(context(open: sessions), ask([0, 1, 2]), "open item resumes the newer session")
        assertDecision(context(row: try row(sessions)), ask([0, 1, 2]), "Library row")
    }

    /// "Mark complete" by hand leaves the session where it was. Play still resumes it, so the row being completed says
    /// nothing about the place (the rule #4097 fixed: completed is not "starts at 0").
    func testMarkedCompleteWithTheSessionPartWayStillResumesIt() throws {
        let sessions = [session("a", percent: 40, mediaTimeMs: 720_000)]
        let completed = try row(sessions, completedByHand: true)
        XCTAssertTrue(completed.isCompleted)
        assertDecision(context(row: completed), ask([0, 1, 2]), "Library row: the place isn't held, every new Margin is asked about")
        assertDecision(context(open: sessions), ask([0, 1]), "open item: the place is known")
    }

    func testMarkedCompleteWithNoSessionBeginsAtTheStart() throws {
        assertDecision(context(row: try row([], completedByHand: true)), .play(.beginning), "no session to resume")
    }

    // MARK: What is playing

    func testThePlayheadOfTheItemPlayingNowIsThePlace() {
        let playing = { PlayRule.NowPlaying(itemId: "item", mediaTimeMs: $0) }
        assertDecision(context(nowPlaying: playing(700_000), open: [session("a", percent: 5, mediaTimeMs: 60_000)]), ask([0, 1]),
                       "the playhead wins over the saved session")
        assertDecision(context(nowPlaying: playing(60_000), open: [session("a", percent: 99, mediaTimeMs: end)]),
                       .play(.savedPlace(mediaTimeMs: 60_000)), "playing near the start: every Margin is ahead")
        assertDecision(context(nowPlaying: playing(nil)), .play(.savedPlace(mediaTimeMs: 0)), "no playhead reported yet counts as 0")
    }

    func testAnotherItemPlayingSaysNothingAboutThisOne() throws {
        let other = PlayRule.NowPlaying(itemId: "other", mediaTimeMs: 1_700_000)
        assertDecision(context(nowPlaying: other, open: [session("a", percent: 40, mediaTimeMs: 720_000)]), ask([0, 1]), "open item")
        assertDecision(context(nowPlaying: other, row: try row([])), .play(.beginning), "row with no session")
        assertDecision(context(nowPlaying: other, open: [session("a", percent: 5, mediaTimeMs: 60_000)]), .play(.savedPlace(mediaTimeMs: 60_000)),
                       "its own place, not the other item's playhead")
    }

    func testTheItemBeingOpenOrNotChangesOnlyHowTheCostOfFindingThePlaceIsPaid() throws {
        let sessions = [session("a", percent: 40, mediaTimeMs: 720_000)]
        assertDecision(context(open: sessions), ask([0, 1]), "open: the saved place is read")
        assertDecision(context(row: try row(sessions)), ask([0, 1, 2]),
                       "not open: the row holds only a percentage, so every new Margin is asked about, ahead ones too (today's behaviour)")
        let otherItemOpen = PlayRule.Context(
            itemId: "item", surface: .libraryRow, openItem: PlayRule.OpenItem(id: "other", sessions: sessions), libraryRow: try row(sessions),
            newMargins: margins())
        assertDecision(otherItemOpen, ask([0, 1, 2]), "another item open: its sessions are not this item's")
    }

    // MARK: A saved session after a relaunch

    func testASavedSessionReadBackFromSQLiteAfterARelaunchDecidesTheSame() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PlayRuleTests-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let item = Item(id: "item", title: "Episode", mediaType: "podcast", text: nil, externalReference: nil, status: "ready")
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveItem(item)
            try store.saveSession(session("saved", percent: 40, mediaTimeMs: 720_000))
        }
        let relaunched = try SQLiteSessionStore(path: path)
        let sessions = try relaunched.loadSessions(itemId: "item")
        XCTAssertEqual(sessions.map(\.id), ["saved"])
        XCTAssertEqual(PlayRule.startAction(sessions: sessions), .resume(sessions[0]))
        assertDecision(context(open: sessions), ask([0, 1]), "open item, session read back")
        let snapshot = LibraryReadSnapshot(items: [item], sessions: sessions, manifests: [], jobs: [], downloads: [])
        let startup = StartupAudioContext(
            hasAcceptedCurrentTerms: true, hasSupertonicVoice: true, suppressedItemIds: [], liveSpeechFallbackItemIds: [],
            failedItemIds: [], preparingItemId: nil, playingItemId: nil, renderSignature: nil, allowsRendering: true)
        let libraryRow = try XCTUnwrap(LibraryRowBuilder.rows(from: snapshot, context: startup).first)
        assertDecision(context(row: libraryRow), ask([0, 1, 2]), "Library row built from the stored session")
    }

    // MARK: Friend Margins that are a reply, and ones turned down

    func testAReplyToTheListenersOwnMarginBehindThePlaceIsAskedAbout() {
        let sent = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-0001")
        let own = Interjection(
            id: "mine", itemId: "item", sessionId: "s", targetType: .item, targetId: "item", createdAt: early, roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
            audioPath: "mine.m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", sharedAs: [sent])
        let link = MarginReplyLink.replying(to: sent, parentConversationId: nil)
        let reply = SharedMarginReview.entries(layers: [layer()], records: ["ana": [record("reply", at: 755_000, replyLinks: [link])]], ownMargins: [own])
        XCTAssertEqual(reply.first?.replyContext?.caption, "Reply to your Margin at 12:34", "the fixture is a reply")
        let replyId = SharedMarginReview.marginId(layerId: "ana", interjectionId: "reply")
        func outcome(placeMs: Int) -> PlayRule.Outcome {
            PlayRule.decide(context(open: [session("a", percent: 50, mediaTimeMs: placeMs)], margins: reply))
        }
        XCTAssertEqual(outcome(placeMs: 900_000), .askFirst(marginsBehind: reply), "the listener is past the reply")
        XCTAssertEqual(outcome(placeMs: 700_000), .play(.savedPlace(mediaTimeMs: 700_000)), "the reply is still ahead")
        XCTAssertEqual(reply.map(\.marginId), [replyId])
    }

    func testMarginsAlreadyTurnedDownAreNotAskedAboutAgainUntilAnotherArrives() {
        let sessions = [session("a", percent: 40, mediaTimeMs: 720_000)]
        var declined = NewMarginsOfferMemory()
        declined.decline(itemId: "item", margins: [marginId(0), marginId(1)])
        assertDecision(context(open: sessions, declined: declined), .play(.savedPlace(mediaTimeMs: 720_000)), "turned down")
        let withANewOne = margins([120_000, 600_000, 650_000])
        assertDecision(context(open: sessions, margins: withANewOne, declined: declined), .askFirst(marginsBehind: withANewOne), "another Margin arrived behind the place")
        var elsewhere = NewMarginsOfferMemory()
        elsewhere.decline(itemId: "other", margins: [marginId(0), marginId(1)])
        assertDecision(context(open: sessions, declined: elsewhere), ask([0, 1]), "turned down on another item")
    }

    // MARK: The item screen's Play

    /// Pinned to what `main` does today (#3219): the item screen's Play starts in place and asks nothing, so a Margin
    /// behind the saved place is skipped. #4125 is the open question; it changes this row and nothing else here.
    func testTheItemScreensPlayDoesNotAskToday() throws {
        let sessions = [session("a", percent: 99, mediaTimeMs: end)]
        assertDecision(context(surface: .itemScreen, open: sessions), .play(.savedPlace(mediaTimeMs: end)), "left at the end, Margins behind")
        assertDecision(context(surface: .itemScreen, open: [finished()]), .play(.beginning), "finished: replays")
        assertDecision(context(surface: .itemScreen, open: []), .play(.beginning), "not started")
        assertDecision(context(surface: .itemScreen, row: try row(sessions)), .play(.savedPlace(mediaTimeMs: nil)), "row only")
    }

    // MARK: What startItem does with the saved sessions

    func testStartResumesTheSessionPlayResumesAndOtherwiseBeginsANewOne() {
        let inProgress = session("a", percent: 40, mediaTimeMs: 720_000)
        let table: [(String, [Session], PlayRule.StartAction)] = [
            ("no sessions", [], .startNew),
            ("in progress", [inProgress], .resume(inProgress)),
            ("99% left at its end", [session("b", percent: 99, mediaTimeMs: end)], .resume(session("b", percent: 99, mediaTimeMs: end))),
            ("finished", [finished()], .startNew),
            ("abandoned only", [session("c", phase: .abandoned, percent: 50, mediaTimeMs: 900_000)], .startNew),
            ("newer in progress, older finished", [finished(updated: 1), session("a", percent: 40, mediaTimeMs: 720_000, updated: 2)],
             .resume(session("a", percent: 40, mediaTimeMs: 720_000, updated: 2))),
            ("newer finished, older in progress", [session("a", percent: 40, mediaTimeMs: 720_000, updated: 1), finished(updated: 2)], .startNew),
        ]
        for (name, sessions, expected) in table {
            XCTAssertEqual(PlayRule.startAction(sessions: sessions), expected, name)
        }
    }

    // MARK: Margins behind the saved place on the item screen (#4125)

    private func textSession(_ id: String, charOffset: Int, percent: Int = 40) -> Session {
        Session(
            id: id, itemId: "item", updatedAt: Date(timeIntervalSince1970: 1), status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: charOffset, mediaTimeMs: nil), completionPercent: percent, playbackRate: 1)
    }

    /// A Margin at a media time and, for an article, a character position.
    private func entry(_ id: String, mediaMs: Int, char: Int?) -> SharedMarginReview.Entry {
        let record = ImportedCommentaryInterjection(
            id: id, layerId: "ana", packageScopedId: id, createdAt: early,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(
                evidenceClass: .acousticVerified, localStartChar: char, localMediaTimeMs: mediaMs, confidence: 1))
        return SharedMarginReview.Entry(layer: layer(), interjection: record, mediaTimeMs: mediaMs, isApproximate: false)
    }

    /// One row per state the design lists (#4125). Media compares by time, text by character, and a place unknown on
    /// either side is not behind. Row "left at the end" fails on `main`, which has no such function and skips them.
    func testWhichMarginsSitBehindTheSavedPlaceOnTheItemScreen() {
        let all = margins() // 2:00, 10:00, 25:00
        let ids = { (entries: [SharedMarginReview.Entry]) in entries.map(\.marginId) }
        let table: [(String, [Session], [SharedMarginReview.Entry], [String])] = [
            ("not started", [], all, []),
            ("mid-way: the first two are behind", [session("a", percent: 40, mediaTimeMs: 720_000)], all, [marginId(0), marginId(1)]),
            ("before the first Margin", [session("a", percent: 2, mediaTimeMs: 30_000)], all, []),
            ("exactly at a Margin: that one plays in place", [session("a", percent: 5, mediaTimeMs: 120_000)], all, []),
            ("left at the end: every one is behind", [session("a", percent: 99, mediaTimeMs: end)], all, [marginId(0), marginId(1), marginId(2)]),
            ("finished: replays from 0, none behind", [finished()], all, []),
            ("marked 100% but not finished: replays from 0, none behind", [session("a", percent: 100, mediaTimeMs: end)], all, []),
            ("an older finished beside a newer one in progress",
             [finished(updated: 1), session("b", percent: 40, mediaTimeMs: 720_000, updated: 2)], all, [marginId(0), marginId(1)]),
            ("a newer finished beside an older one in progress",
             [session("b", percent: 40, mediaTimeMs: 720_000, updated: 1), finished(updated: 2)], all, []),
            ("abandoned only", [session("c", phase: .abandoned, percent: 50, mediaTimeMs: 900_000)], all, []),
            ("media session with no place yet", [session("a", percent: 0)], all, []),
            ("no Margins", [session("a", percent: 40, mediaTimeMs: 720_000)], [], []),
        ]
        for (name, sessions, entries, expected) in table {
            XCTAssertEqual(ids(PlayRule.marginsBehindSavedPlace(entries, sessions: sessions)), expected, name)
        }
    }

    func testAnArticlesMarginsAreComparedByCharacterNotMediaTime() {
        let behind = entry("m0", mediaMs: 5_000, char: 400)
        let ahead = entry("m1", mediaMs: 5_000, char: 4_000)
        let unplaced = entry("m2", mediaMs: 5_000, char: nil)
        let atPlace = entry("m3", mediaMs: 5_000, char: 1_000)
        let sessions = [textSession("t", charOffset: 1_000)]
        let result = PlayRule.marginsBehindSavedPlace([behind, ahead, unplaced, atPlace], sessions: sessions)
        XCTAssertEqual(result.map(\.marginId), [behind.marginId], "only the one before the offset; unplaced is not behind")
        XCTAssertEqual(
            PlayRule.marginsBehindSavedPlace([behind], sessions: [textSession("t", charOffset: 0)]), [],
            "a text session at the start has nothing behind it")
    }

    func testTheSavedPlaceIsAtTheEndOnlyFromNinetyNineUpToButNotIncludingOneHundred() {
        let table: [(String, [Session], Bool)] = [
            ("none", [], false),
            ("40%", [session("a", percent: 40, mediaTimeMs: 720_000)], false),
            ("98%", [session("a", percent: 98, mediaTimeMs: 1_764_000)], false),
            ("99%", [session("a", percent: 99, mediaTimeMs: end)], true),
            ("100%: begins again", [session("a", percent: 100, mediaTimeMs: end)], false),
            ("finished", [finished()], false),
            ("a newer 99% over an older 40%",
             [session("a", percent: 40, mediaTimeMs: 720_000, updated: 1), session("b", percent: 99, mediaTimeMs: end, updated: 2)], true),
        ]
        for (name, sessions, expected) in table {
            XCTAssertEqual(PlayRule.savedPlaceIsAtEnd(sessions: sessions), expected, name)
        }
    }

    /// The Library row keeps asking about every Margin it can't place, as before: the new function is for a surface
    /// that holds the sessions, and `decide` is unchanged.
    func testTheLibraryRowStillAsksAboutEveryMarginItCannotPlace() throws {
        let sessions = [session("a", percent: 99, mediaTimeMs: end)]
        assertDecision(context(row: try row(sessions)), ask([0, 1, 2]), "row only, left at the end")
    }
}
