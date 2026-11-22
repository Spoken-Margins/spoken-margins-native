import XCTest
@testable import SessionKit

/// #4688: the Share Margins sheet held one listening pass, so a replay hid the first listen's Margins. These rows pin
/// what it now starts with: every shareable Margin of every pass, in the order they sit in the item.
final class ItemShareCandidatesTests: XCTestCase {
    private let recording = AudioSourceType.nativeMediaFile.rawValue
    private let text = "html"

    private func make(
        _ ids: [String], _ bySession: [String: [Interjection]], source: String?
    ) -> ItemShareCandidates {
        ItemShareCandidates.make(sessionIdsNewestFirst: ids, marginsBySession: bySession, mediaSourceType: source)
    }

    func testOnePass() {
        let result = make(["a"], ["a": [margin("m1", session: "a", ms: 1_000), margin("m2", session: "a", ms: 2_000)]], source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["m1", "m2"])
        XCTAssertEqual(result.sessionId, "a")
    }

    func testTwoPassesOfARecordingComeBackInMediaTimeOrder() {
        let bySession = [
            "old": [margin("five", session: "old", ms: 300_000)],
            "new": [margin("nine", session: "new", ms: 540_000), margin("two", session: "new", ms: 120_000)],
        ]
        let result = make(["new", "old"], bySession, source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["two", "five", "nine"])
    }

    func testTwoPassesOfATextComeBackInTextOrder() {
        let bySession = [
            "old": [margin("late", session: "old", startChar: 900), margin("early", session: "old", startChar: 10)],
            "new": [margin("middle", session: "new", startChar: 400)],
        ]
        XCTAssertEqual(make(["new", "old"], bySession, source: text).margins.map(\.id), ["early", "middle", "late"])
        XCTAssertEqual(make(["new", "old"], bySession, source: nil).margins.map(\.id), ["early", "middle", "late"],
                       "no media source is a text")
    }

    func testANewerEmptyPassStillGivesTheOlderPassesMargins() {
        let bySession = ["new": [Interjection](), "old": [margin("m1", session: "old", ms: 5_000)]]
        let result = make(["new", "old"], bySession, source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["m1"])
        XCTAssertEqual(result.sessionId, "old")
    }

    func testMarginsMadeOnASummaryOrAnAnswerAreLeftOut() {
        let bySession = [
            "old": [margin("summary", session: "old", target: .summaryTurn), margin("answer", session: "old", target: .assistantTurn)],
            "new": [margin("source", session: "new", ms: 1_000)],
        ]
        XCTAssertEqual(make(["new", "old"], bySession, source: recording).margins.map(\.id), ["source"])
    }

    func testDeletedMarginsAreLeftOut() {
        let bySession = ["a": [margin("gone", session: "a", ms: 1_000, status: "deleted"), margin("kept", session: "a", ms: 2_000)]]
        XCTAssertEqual(make(["a"], bySession, source: recording).margins.map(\.id), ["kept"])
    }

    func testAMarginWithNoPlaceIsReturnedLast() {
        let bySession = [
            "old": [unplaced("floating", session: "old")],
            "new": [margin("placed", session: "new", ms: 90_000_000)],
        ]
        let result = make(["new", "old"], bySession, source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["placed", "floating"])
    }

    func testOnlyMarginsWithNoPlaceAreStillReturnedSoTheSheetCanSayWhy() {
        let result = make(["a"], ["a": [unplaced("floating", session: "a")]], source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["floating"])
        XCTAssertEqual(result.sessionId, "a")
    }

    func testTheSameMarginInTwoPassesIsReturnedOnce() {
        let shared = margin("same", session: "old", ms: 1_000)
        let result = make(["new", "old"], ["new": [shared], "old": [shared]], source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["same"])
    }

    /// Passes are read newest first, so when two copies of an id differ the newest pass's copy is the one kept.
    func testTheFirstCopySeenWins() {
        let newer = margin("same", session: "new", ms: 1_000, createdAt: 50)
        let older = margin("same", session: "old", ms: 1_000, createdAt: 10)
        let result = make(["new", "old"], ["new": [newer], "old": [older]], source: recording)
        XCTAssertEqual(result.margins.map(\.sessionId), ["new"])
    }

    func testMarginsWithNoPlaceKeepWhenTheyWereMadeOrderAmongThemselves() {
        var late = unplaced("late", session: "a"); late.createdAt = Date(timeIntervalSince1970: 20)
        var early = unplaced("early", session: "a"); early.createdAt = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(make(["a"], ["a": [late, early]], source: recording).margins.map(\.id), ["early", "late"])
    }

    func testEqualPlacesGoByWhenTheyWereMadeThenById() {
        let bySession = ["a": [
            margin("b", session: "a", ms: 1_000, createdAt: 20), margin("z", session: "a", ms: 1_000, createdAt: 10),
            margin("a", session: "a", ms: 1_000, createdAt: 10),
        ]]
        XCTAssertEqual(make(["a"], bySession, source: recording).margins.map(\.id), ["a", "z", "b"])
    }

    func testNoSessionsGivesNothing() {
        let result = make([], [:], source: recording)
        XCTAssertEqual(result.margins, [])
        XCTAssertNil(result.sessionId)
    }

    func testAPassMissingFromTheReadsIsTreatedAsEmpty() {
        let result = make(["unread", "a"], ["a": [margin("m1", session: "a", ms: 1_000)]], source: recording)
        XCTAssertEqual(result.margins.map(\.id), ["m1"])
        XCTAssertEqual(result.sessionId, "a")
    }

    /// Export reads `sessionId`, so it must stay the pass `ItemShareSessionSelection` picks.
    func testSessionIdMatchesTheOldSelectionRule() {
        let cases: [([String], [String: [Interjection]])] = [
            (["a"], ["a": [margin("m1", session: "a", ms: 1_000)]]),
            (["new", "old"], ["new": [margin("m2", session: "new", ms: 1_000)], "old": [margin("m1", session: "old", ms: 1_000)]]),
            (["new", "old"], ["new": [], "old": [margin("m1", session: "old", ms: 1_000)]]),
            (["new", "old"], ["new": [unplaced("u", session: "new")], "old": [margin("m1", session: "old", ms: 1_000)]]),
            (["new", "old"], ["new": [unplaced("u", session: "new")], "old": [unplaced("v", session: "old")]]),
            (["new"], ["new": [margin("r", session: "new", target: .assistantTurn)]]),
        ]
        for (ids, bySession) in cases {
            XCTAssertEqual(
                make(ids, bySession, source: recording).sessionId,
                ItemShareSessionSelection.sessionId(newestFirst: ids) { bySession[$0] ?? [] }, "\(ids)")
        }
    }

    private func unplaced(_ id: String, session: String) -> Interjection {
        var m = margin(id, session: session, ms: 0)
        m.movedOrigin = MovedMarginOrigin(
            marginId: id, itemId: "item", sessionId: session, liveMarginId: "l", fromLiveSessionId: "live",
            fromLiveSessionTitle: "Quick", markedAt: m.createdAt, movedAt: m.createdAt, placeKnown: false)
        return m
    }

    private func margin(
        _ id: String, session: String, target: InterjectionTargetType = .item, ms: Int? = nil, startChar: Int = 0,
        status: String = "active", createdAt: TimeInterval = 0
    ) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: session, targetType: target, targetId: target == .item ? "item" : "turn",
            createdAt: Date(timeIntervalSince1970: createdAt), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: startChar, endChar: startChar + 4, anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: id,
            cleanedTranscript: nil, displayText: id, status: status, captureKind: .written
        )
    }
}
