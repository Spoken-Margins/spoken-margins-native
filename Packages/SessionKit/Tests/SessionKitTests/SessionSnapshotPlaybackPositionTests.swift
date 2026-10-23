import XCTest
@testable import SessionKit

final class SessionSnapshotPlaybackPositionTests: XCTestCase {
    /// The fields that move with every progress tick.
    private static let positionFields: Set<String> = [
        "currentMediaTimeMs", "currentTextStart", "currentTextEnd", "currentTranscriptSegmentId"
    ]

    /// Every other stored field. A field added to `SessionSnapshot` fails here until it is listed, so someone decides
    /// whether views must hear about it on every tick (a position field) or only when it changes.
    private static let otherFields: Set<String> = [
        "sessionId", "itemId", "targetType", "targetId", "status", "phase", "title", "chapterTitle",
        "progressPercent", "sourceProgressPercent", "currentPlaybackProgressPercent", "currentPlaybackDurationMs",
        "currentAnchorConfidence", "playbackRate", "isRecording", "activeInterjectionCount", "pendingAiJobCount",
        "lastInterjectionAnchorType", "lastInterjectionTargetType", "recordingTargetId", "pendingAiJobKind",
        "pendingAiJobStatus", "providerCallStarted", "turnStatus", "lastUserTurnType", "spokenUnits", "lastFailure",
        "linkResolutionStatus", "linkResolutionFailureReason", "preparedTextAudioStatus", "sourceTranscriptStatus",
        "skimBridgeState", "canSkimForward", "canSkimBackward", "playbackRequestedAt"
    ]

    private func playingSnapshot() -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "item"
        snapshot.status = .playing
        snapshot.currentMediaTimeMs = 10_000
        snapshot.currentTextStart = 100
        snapshot.currentTextEnd = 140
        snapshot.currentTranscriptSegmentId = "seg-1"
        snapshot.sourceProgressPercent = 12
        return snapshot
    }

    func testEveryStoredFieldIsClassifiedAsPositionOrNot() {
        let labels = Set(Mirror(reflecting: SessionSnapshot()).children.compactMap(\.label))
        XCTAssertEqual(labels, Self.positionFields.union(Self.otherFields))
        XCTAssertTrue(Self.positionFields.isDisjoint(with: Self.otherFields))
    }

    func testAProgressTickThatMovesOnlyThePositionIsNotACrossScreenChange() {
        let before = playingSnapshot()
        var after = before
        after.currentMediaTimeMs = 10_500
        after.currentTextStart = 180
        after.currentTextEnd = 230
        after.currentTranscriptSegmentId = "seg-2"
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.equalIgnoringPlaybackPosition(to: before))
        XCTAssertTrue(before.equalIgnoringPlaybackPosition(to: after))
        XCTAssertEqual(after.tickPosition, PlaybackTickPosition(
            mediaTimeMs: 10_500, textStart: 180, textEnd: 230, transcriptSegmentId: "seg-2"))
    }

    func testAnIdenticalSnapshotHasNoChange() {
        XCTAssertTrue(playingSnapshot().equalIgnoringPlaybackPosition(to: playingSnapshot()))
    }

    func testAnyOtherChangeStillCountsEvenWhenThePositionMovesWithIt() {
        let before = playingSnapshot()
        let changes: [(String, (inout SessionSnapshot) -> Void)] = [
            ("status", { $0.status = .paused }),
            ("target", { $0.targetId = "turn-1" }),
            ("chapter", { $0.chapterTitle = "Second chapter" }),
            ("whole percent", { $0.sourceProgressPercent = 13 }),
            ("playback percent", { $0.currentPlaybackProgressPercent = 7 }),
            ("duration", { $0.currentPlaybackDurationMs = 90_000 }),
            ("item", { $0.itemId = "other" }),
            ("skim", { $0.canSkimForward = true }),
            ("failure", { $0.lastFailure = "route lost" }),
            ("speed", { $0.playbackRate = 1.5 })
        ]
        for (name, change) in changes {
            var after = before
            change(&after)
            after.currentMediaTimeMs = 10_500 // the position moving too must not hide it
            XCTAssertFalse(after.equalIgnoringPlaybackPosition(to: before), "\(name) change was treated as a tick")
        }
    }

    func testItemFlagReadsOncePerItemUntilInvalidated() {
        let flag = CachedItemFlag()
        var reads = 0
        func load(_ answer: Bool) -> () -> Bool { { reads += 1; return answer } }
        XCTAssertTrue(flag.value(itemID: "a", load: load(true)))
        XCTAssertTrue(flag.value(itemID: "a", load: load(false)))
        XCTAssertTrue(flag.value(itemID: "a", load: load(false)))
        XCTAssertEqual(reads, 1, "a repeated read of the same item must not reach the store again")
        XCTAssertFalse(flag.value(itemID: "b", load: load(false)))
        XCTAssertEqual(reads, 2)
        flag.invalidate()
        XCTAssertTrue(flag.value(itemID: "b", load: load(true)))
        XCTAssertEqual(reads, 3)
    }
}
