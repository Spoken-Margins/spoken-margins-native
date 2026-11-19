import Foundation
import XCTest
@testable import SessionKit

/// #4339 PR 4: when the Tidy version card on a Margin's details screen is offered, used or absent.
final class MarginTidyCardStateTests: XCTestCase {
    private func margin(
        status: String = "active", transcription: String = "transcribed", transcript: String? = "um so the result",
        cleaned: String? = nil, kind: InterjectionCaptureKind? = nil, decision: MarginTidyDecision? = nil
    ) -> Interjection {
        var margin = Interjection(
            id: "m1", itemId: "item", sessionId: "s", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: "interjections/m1.m4a", audioStatus: "saved", transcriptionStatus: transcription,
            transcript: transcript, cleanedTranscript: cleaned, displayText: cleaned ?? transcript, status: status
        )
        margin.captureKind = kind
        margin.tidyDecision = decision
        return margin
    }

    func testAnUnansweredSpokenMarginWithAReadyTranscriptIsACandidate() {
        XCTAssertEqual(MarginTidyCardState.state(for: margin()), .candidate(transcript: "um so the result"))
        XCTAssertEqual(MarginTidyCardState.state(for: margin(transcription: "complete")), .candidate(transcript: "um so the result"))
        XCTAssertEqual(MarginTidyCardState.state(for: margin(kind: .audio)), .candidate(transcript: "um so the result"))
    }

    func testNoCardWhereThereIsNothingToTidy() {
        XCTAssertEqual(MarginTidyCardState.state(for: margin(kind: .written)), .hidden, "a written Margin")
        XCTAssertEqual(MarginTidyCardState.state(for: margin(status: "deleted")), .hidden)
        for status in ["pending", "transcribing", "failed", "requested", ""] {
            XCTAssertEqual(MarginTidyCardState.state(for: margin(transcription: status)), .hidden, "transcription \(status)")
        }
        for transcript in [nil, "", "   \n"] {
            XCTAssertEqual(MarginTidyCardState.state(for: margin(transcript: transcript)), .hidden, "transcript \(String(describing: transcript))")
        }
    }

    func testTheAnswerDecidesTheCard() {
        let used = MarginTidyDecision(choice: .usedTidy, source: .fillers, decidedAt: Date(timeIntervalSince1970: 1))
        let kept = MarginTidyDecision(choice: .keptOriginal, decidedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(MarginTidyCardState.state(for: margin(cleaned: "The result.", decision: used)), .used)
        XCTAssertEqual(MarginTidyCardState.state(for: margin(decision: kept)), .hidden, "Keep mine is not offered again")
    }

    func testCleanedTextThatIsNotFromAnAnswerIsNeverWrittenOver() {
        XCTAssertEqual(MarginTidyCardState.state(for: margin(cleaned: "Someone else's cleanup.")), .hidden)
        XCTAssertEqual(MarginTidyCardState.state(for: margin(cleaned: "")), .candidate(transcript: "um so the result"), "empty cleaned text is none")
    }

    func testCaptionsAndStoredSourcesFollowTheProposalSource() {
        XCTAssertEqual(MarginTidyCardState.caption(for: .fillers), "Fillers removed.")
        XCTAssertEqual(MarginTidyCardState.caption(for: .onDeviceAI), "Tidied on this iPhone, using the passage around it.")
        XCTAssertEqual(MarginTidyCardState.decisionSource(for: .fillers), .fillers)
        XCTAssertEqual(MarginTidyCardState.decisionSource(for: .onDeviceAI), .onDeviceAI)
    }
}
