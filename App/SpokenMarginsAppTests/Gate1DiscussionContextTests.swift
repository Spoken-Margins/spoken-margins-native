import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

final class Gate1DiscussionContextTests: XCTestCase {
    func testDiscussionUsesAllCurrentAssistantTurnInterjectionsRegardlessOfSummaryState() {
        let currentOne = interjection(id: "ij-ai-1", targetType: .assistantTurn, targetId: "turn-response-003", transcript: "First point on the latest response.")
        let currentTwo = interjection(id: "ij-ai-2", targetType: .assistantTurn, targetId: "turn-response-003", transcript: "Second point on the latest response.")
        let prior = interjection(id: "ij-ai-old", targetType: .assistantTurn, targetId: "turn-response-002", transcript: "Prior response point.")
        let item = interjection(id: "ij-item", targetType: .item, targetId: "item-pill", transcript: "Source point.")

        let selected = Gate1DiscussionContext.currentTargetInterjections(
            interjections: [currentOne, prior, item, currentTwo],
            currentTargetType: TargetType.assistantTurnTTS.rawValue,
            currentTargetId: "turn-response-003",
            itemId: "item-pill"
        )

        XCTAssertEqual(selected.map(\.id), ["ij-ai-1", "ij-ai-2"])
    }

    func testDiscussionUsesItemInterjectionsWhenCurrentTargetIsSource() {
        let itemOne = interjection(id: "ij-item-1", targetType: .item, targetId: "item-pill", transcript: "First item point.")
        let itemTwo = interjection(id: "ij-item-2", targetType: .item, targetId: "item-pill", transcript: "Second item point.")
        let ai = interjection(id: "ij-ai", targetType: .assistantTurn, targetId: "turn-response-001", transcript: "AI point.")

        let selected = Gate1DiscussionContext.currentTargetInterjections(
            interjections: [itemOne, ai, itemTwo],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item-pill",
            itemId: "item-pill"
        )

        XCTAssertEqual(selected.map(\.id), ["ij-item-1", "ij-item-2"])
    }

    func testPrimaryRequestFallsBackToCurrentInterjectionBundle() {
        let first = interjection(id: "ij-1", targetType: .assistantTurn, targetId: "turn-response-003", transcript: "Make this a single paragraph.")
        let second = interjection(id: "ij-2", targetType: .assistantTurn, targetId: "turn-response-003", transcript: "Do not review the article again.")

        let request = Gate1DiscussionContext.primaryRequest(explicitFollowUp: "", currentInterjections: [first, second])

        XCTAssertTrue(request.contains("Respond to the current conversation change"))
        XCTAssertTrue(request.contains("Make this a single paragraph."))
        XCTAssertTrue(request.contains("Do not review the article again."))
    }

    func testExplicitFollowupRemainsPrimaryWhenProvided() {
        let interjection = interjection(id: "ij-1", targetType: .assistantTurn, targetId: "turn-response-003", transcript: "Background point.")

        XCTAssertEqual(
            Gate1DiscussionContext.primaryRequest(explicitFollowUp: "Answer this typed question.", currentInterjections: [interjection]),
            "Answer this typed question."
        )
        XCTAssertEqual(
            Gate1DiscussionContext.primaryIntentSource(explicitFollowUp: "Answer this typed question.", currentInterjections: [interjection]),
            "typed_follow_up"
        )
    }

    private func interjection(id: String, targetType: InterjectionTargetType, targetId: String, transcript: String) -> Interjection {
        Interjection(
            id: id,
            itemId: "item-pill",
            sessionId: "session-1",
            targetType: targetType,
            targetId: targetId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(anchorType: targetType == .item ? .text : .turn, startChar: 0, endChar: 8, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: transcript,
            cleanedTranscript: nil,
            displayText: transcript,
            status: "active"
        )
    }
}
