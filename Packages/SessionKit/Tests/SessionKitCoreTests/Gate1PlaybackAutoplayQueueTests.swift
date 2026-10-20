import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class Gate1PlaybackAutoplayQueueTests: XCTestCase {
    func testSourceFinishAllowsQueuedSummaryToAutoplay() {
        var queue = Gate1PlaybackAutoplayQueue()
        queue.enqueue("turn-summary-001")
        var snapshot = SessionSnapshot()
        snapshot.status = .playing
        snapshot.phase = .itemPlayback
        snapshot.targetId = "item-pill"

        XCTAssertNil(queue.popReadyTurn(snapshot: snapshot))
        XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true), "turn-summary-001")
    }

    func testCompletedCurrentAudioPreventsDeferringGeneratedSummaryOnStalePlayingSnapshot() {
        let queue = Gate1PlaybackAutoplayQueue()
        var snapshot = SessionSnapshot()
        snapshot.status = .playing
        snapshot.phase = .itemPlayback
        snapshot.targetId = "item-pill"

        XCTAssertTrue(queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn-summary-001"))
        XCTAssertFalse(queue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: "turn-summary-001",
            completedCurrentAudio: true
        ))
    }

    func testPartialOriginalSourceBlocksGeneratedTurnEvenAfterCurrentAudioCompletes() {
        var queue = Gate1PlaybackAutoplayQueue()
        queue.enqueue("turn-response-001")
        var snapshot = SessionSnapshot()
        snapshot.status = .paused
        snapshot.phase = .itemPlayback
        snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        snapshot.targetId = "file:///tmp/generated-starter.caf"
        snapshot.sourceProgressPercent = 8

        XCTAssertTrue(queue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: "turn-response-001",
            completedCurrentAudio: true
        ))
        XCTAssertNil(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true))
    }

    /// The article, the podcast with a transcript and the browser-owned player all count as "the original
    /// content" a generated summary or reply must not barge into (APA-14). The old tests blocked only
    /// `transcriptBackedMedia` at 8 percent, so dropping `itemTextTTS` (the default voice reading an article)
    /// or `browserOwnedMedia` from the list went unseen.
    func testAnUnfinishedOriginalOfAnyKindDefersAGeneratedTurnEvenAfterCurrentAudioCompletes() {
        for target in [TargetType.itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia] {
            var queue = Gate1PlaybackAutoplayQueue()
            queue.enqueue("turn-summary-001")
            let snapshot = snapshot(target: target, sourceProgressPercent: 8, phase: .itemPlayback, status: .paused)

            XCTAssertTrue(
                queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn-summary-001", completedCurrentAudio: true),
                "\(target.rawValue) at 8 percent"
            )
            XCTAssertFalse(
                queue.shouldPlayPendingTurnNow(snapshot: snapshot, turnId: "turn-summary-001", completedCurrentAudio: true),
                "\(target.rawValue) at 8 percent"
            )
            XCTAssertNil(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true), "\(target.rawValue) at 8 percent")
            XCTAssertEqual(queue.pendingTurnIds, ["turn-summary-001"], "the turn waits, it is not dropped")
        }
    }

    /// The boundary: a source at 100 percent is finished, and the queued turn is released (APA-14, the `< 100` test).
    func testAFinishedOriginalOfAnyKindReleasesAQueuedTurn() {
        for target in [TargetType.itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia] {
            for (percent, phase) in [(100, SessionPhase.itemPlayback), (99, .finished)] {
                var queue = Gate1PlaybackAutoplayQueue()
                queue.enqueue("turn-summary-001")
                let snapshot = snapshot(target: target, sourceProgressPercent: percent, phase: phase, status: .playing)
                let label = "\(target.rawValue) at \(percent) percent in \(phase.rawValue)"

                XCTAssertFalse(
                    queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn-summary-001", completedCurrentAudio: true),
                    label
                )
                XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true), "turn-summary-001", label)
            }
        }
    }

    /// 99 percent is still unfinished; only 100 releases (a `<= 100` slip would never release at the end).
    func testOneShortOfTheEndStillDefers() {
        for target in [TargetType.itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia] {
            let queue = Gate1PlaybackAutoplayQueue()
            let snapshot = snapshot(target: target, sourceProgressPercent: 99, phase: .itemPlayback, status: .paused)
            XCTAssertTrue(
                queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn-summary-001", completedCurrentAudio: true),
                target.rawValue
            )
        }
    }

    /// Generated audio is not "original content": a summary playing at 8 percent of the article does not hold the next turn
    /// back on account of the percent, only on account of what is playing.
    func testOnlyOriginalContentTargetsAreHeldByTheSourcePercent() {
        for target in [TargetType.summaryTurnTTS, .assistantTurnTTS] {
            var queue = Gate1PlaybackAutoplayQueue()
            queue.enqueue("turn-response-001")
            let snapshot = snapshot(target: target, sourceProgressPercent: 8, phase: .summaryPlayback, status: .paused)
            XCTAssertFalse(
                queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn-response-001", completedCurrentAudio: true),
                target.rawValue
            )
            XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true), "turn-response-001", target.rawValue)
        }
    }

    func testInterjectionSummaryFinishAllowsQueuedDiscussionToAutoplay() {
        var queue = Gate1PlaybackAutoplayQueue()
        queue.enqueue("turn-response-001")
        var snapshot = SessionSnapshot()
        snapshot.status = .playing
        snapshot.phase = .summaryPlayback
        snapshot.targetId = "turn-summary-001"

        XCTAssertNil(queue.popReadyTurn(snapshot: snapshot))
        XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: true), "turn-response-001")
    }

    func testManualTimelineNavigationClearsPendingAutoplay() {
        var queue = Gate1PlaybackAutoplayQueue()
        queue.enqueue("turn-summary-001")
        queue.enqueue("turn-response-001")

        queue.clear()

        XCTAssertNil(queue.first)
        XCTAssertEqual(queue.count, 0)
    }

    func testMultipleGeneratedTurnsDrainFIFO() {
        var queue = Gate1PlaybackAutoplayQueue()
        queue.enqueue("turn-summary-001")
        queue.enqueue("turn-response-001")
        queue.enqueue("turn-summary-002")
        queue.enqueue("turn-summary-001")
        XCTAssertEqual(queue.pendingTurnIds, ["turn-summary-001", "turn-response-001", "turn-summary-002"])
        var snapshot = SessionSnapshot()
        snapshot.status = .paused
        snapshot.phase = .conversation
        snapshot.targetId = "item-pill"

        XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot), "turn-summary-001")
        XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot), "turn-response-001")
        XCTAssertEqual(queue.popReadyTurn(snapshot: snapshot), "turn-summary-002")
        XCTAssertNil(queue.popReadyTurn(snapshot: snapshot))
    }

    func testSummaryRegenerationIsBlockedUntilNewInterjectionExistsForCurrentTarget() {
        let firstInterjection = interjection(id: "ij-1", targetType: .item, targetId: "item-pill")
        let secondInterjection = interjection(id: "ij-2", targetType: .item, targetId: "item-pill")
        let existingSummary = ConversationTurn(
            id: "turn-summary-001",
            sessionId: "session-1",
            role: "assistant",
            turnType: "interjection_summary",
            status: "complete",
            summary: nil,
            text: "Summary.",
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: ["ij-1"]
        )

        XCTAssertTrue(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [existingSummary],
            interjections: [firstInterjection],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item-pill"
        ).isEmpty)

        XCTAssertEqual(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [existingSummary],
            interjections: [firstInterjection, secondInterjection],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item-pill"
        ).map(\.id), ["ij-2"])
    }

    func testFailedPartialSummaryKeepsItsInterjectionsEligibleForRetry() {
        let interjection = interjection(id: "ij-1", targetType: .item, targetId: "item-pill")
        let interruptedSummary = ConversationTurn(
            id: "turn-summary-001",
            sessionId: "session-1",
            role: "assistant",
            turnType: "interjection_summary",
            status: "failed_partial",
            summary: nil,
            text: "Incomplete summary.",
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: [interjection.id]
        )

        XCTAssertEqual(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [interruptedSummary],
            interjections: [interjection],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item-pill"
        ).map(\.id), [interjection.id])
    }

    func testAITurnSummaryEligibilityUsesCurrentTurnOnly() {
        let aiInterjection = interjection(id: "ij-ai", targetType: .assistantTurn, targetId: "turn-response-001")
        let otherAIInterjection = interjection(id: "ij-other", targetType: .assistantTurn, targetId: "turn-response-002")

        XCTAssertEqual(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [],
            interjections: [aiInterjection, otherAIInterjection],
            currentTargetType: TargetType.assistantTurnTTS.rawValue,
            currentTargetId: "turn-response-001"
        ).map(\.id), ["ij-ai"])
    }

    func testDeletedInterjectionIsNeverEligible() {
        var deleted = interjection(id: "ij-deleted", targetType: .item, targetId: "item-pill")
        deleted.status = "deleted"
        XCTAssertTrue(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [],
            interjections: [deleted],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item-pill"
        ).isEmpty)
    }

    func testMovedAPINamesAndModelDiagnosticsStayStable() throws {
        XCTAssertEqual(String(describing: Gate1PlaybackAutoplayQueue.self), "Gate1PlaybackAutoplayQueue")
        XCTAssertEqual(String(describing: Gate1SummaryEligibility.self), "Gate1SummaryEligibility")
        var queue = Gate1PlaybackAutoplayQueue()
        let snapshot = SessionSnapshot()
        XCTAssertNil(queue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: false))
        XCTAssertFalse(queue.shouldDeferGeneratedTurnPlayback(snapshot: snapshot, turnId: "turn", completedCurrentAudio: false))
        XCTAssertTrue(queue.shouldPlayPendingTurnNow(snapshot: snapshot, turnId: "turn", completedCurrentAudio: false))
        XCTAssertTrue(Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [], interjections: [], currentTargetType: "item", currentTargetId: nil
        ).isEmpty)
        let model = try TestInputs.text(.appSources, "Gate1AppModel.swift")
        XCTAssertTrue(model.contains("diagnostics[\"pendingAutoPlayQueue\"]"))
        XCTAssertTrue(model.contains("diagnostics[\"pendingAutoPlayTurnId\"]"))
    }

    private func snapshot(
        target: TargetType, sourceProgressPercent: Int, phase: SessionPhase, status: PlaybackStatus
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.status = status
        snapshot.phase = phase
        snapshot.targetType = target.rawValue
        snapshot.targetId = "item-pill"
        snapshot.sourceProgressPercent = sourceProgressPercent
        return snapshot
    }

    private func interjection(id: String, targetType: InterjectionTargetType, targetId: String) -> Interjection {
        Interjection(
            id: id,
            itemId: "item-pill",
            sessionId: "session-1",
            targetType: targetType,
            targetId: targetId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 10,
            anchor: Anchor(anchorType: targetType == .item ? .text : .turn, startChar: 0, endChar: 8, anchorBefore: "Anchor", anchorAfter: ""),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: "Note",
            cleanedTranscript: nil,
            displayText: "Note",
            status: "active"
        )
    }
}
