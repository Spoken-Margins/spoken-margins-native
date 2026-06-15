import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

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
