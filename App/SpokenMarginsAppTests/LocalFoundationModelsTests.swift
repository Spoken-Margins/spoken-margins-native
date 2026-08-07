import XCTest
import SessionKit
@testable import SpokenMarginsApp

final class LocalFoundationModelsTests: XCTestCase {
    func testInterjectionRewritePromptTreatsAnchorsAsOptionalContextAndSupportsNoteOnlyRetry() {
        let record = LocalInterjectionSummaryRecord(
            id: "note-1",
            anchorBefore: "A source claim",
            anchorAfter: "More source",
            note: "Maybe this matters"
        )
        let anchored = AppleFoundationModelClient.interjectionRewritePrompt(record: record, includeAnchors: true)
        let noteOnly = AppleFoundationModelClient.interjectionRewritePrompt(record: record, includeAnchors: false)

        XCTAssertTrue(anchored.contains("Remove fillers"))
        XCTAssertTrue(anchored.contains("Preserve viewpoint"))
        XCTAssertTrue(anchored.contains("Do not answer the note"))
        XCTAssertTrue(anchored.contains("OPTIONAL SOURCE CONTEXT"))
        XCTAssertTrue(anchored.contains("A source claim"))
        XCTAssertTrue(noteOnly.contains("Maybe this matters"))
        XCTAssertFalse(noteOnly.contains("OPTIONAL SOURCE CONTEXT"))
        XCTAssertFalse(noteOnly.contains("A source claim"))
    }

    func testSpokenNoteCleanupRemovesFillersAndRepeatedWordsWithoutRemovingUncertainty() {
        let cleaned = LocalInterjectionSummaryPolicy.cleanSpokenNote(
            "So, uh, I, I think that, um, maybe this is a good test."
        )

        XCTAssertEqual(cleaned, "So, I think that, maybe this is a good test")
    }

    func testDeterministicSummaryFallbackKeepsTheCompleteListenerNoteWithoutSourceAnchors() throws {
        let record = LocalInterjectionSummaryRecord(
            id: "note-fallback",
            anchorBefore: "A long publisher passage that must never become the listener's words.",
            anchorAfter: "More publisher language that is context rather than listener intent.",
            note: "Um, I, I am still uncertain whether this premise supports the conclusion, and I want to compare it with the speaker's later qualification before deciding."
        )

        let fallback = try LocalInterjectionSummaryPolicy.fallbackRewrite(for: record)

        XCTAssertEqual(
            fallback,
            "I am still uncertain whether this premise supports the conclusion, and I want to compare it with the speaker's later qualification before deciding"
        )
        XCTAssertFalse(fallback.contains(record.anchorBefore))
        XCTAssertFalse(fallback.contains(record.anchorAfter))
    }

    func testSummaryValidationRejectsAnchorCopyAndResidualFillers() throws {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Source",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "note-1",
                    anchorBefore: "Scaling exploration monotonically improves existing models across images video and language.",
                    anchorAfter: "The next source passage continues with unrelated technical details.",
                    note: "Maybe this tests whether clipped posts remain understandable."
                )
            ]
        )

        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Scaling exploration monotonically improves existing models across images video and language."],
            payload: payload
        ))
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Um, maybe this tests whether clipped posts remain understandable."],
            payload: payload
        ))
        XCTAssertEqual(
            try LocalInterjectionSummaryPolicy.validate(
                bullets: ["Maybe this tests whether clipped posts remain understandable in Spoken Margins."],
                payload: payload
            ),
            ["Maybe this tests whether clipped posts remain understandable in Spoken Margins."]
        )
    }

    func testPartialSummaryReductionProducesStructuredListenerOnlyPayload() throws {
        let payload = try XCTUnwrap(AppleFoundationModelClient.interjectionSummaryPayload(from: """
        PARTIAL 1:
        - The listener questions the first claim.

        PARTIAL 2:
        - The listener wants to compare it with the later example.
        """))

        XCTAssertEqual(payload.schemaVersion, "local-interjection-summary-partials.v1")
        XCTAssertEqual(payload.interjections.count, 2)
        XCTAssertTrue(payload.interjections.allSatisfy { $0.anchorBefore.isEmpty && $0.anchorAfter.isEmpty })
        XCTAssertTrue(payload.interjections[0].note.contains("questions the first claim"))
    }

    func testPlannerUsesSemanticShiftAfterMinimumChunkSize() throws {
        let alpha = String(repeating: "Alpha context evidence structure. ", count: 45)
        let beta = String(repeating: "Beta implementation navigation audio. ", count: 45)
        let source = "\(alpha) \(alpha) \(beta) \(beta)"
        let planner = LocalListeningMapPlanner { text in
            let lowered = text.lowercased()
            let alphaCount = Double(lowered.components(separatedBy: "alpha").count - 1)
            let betaCount = Double(lowered.components(separatedBy: "beta").count - 1)
            return [alphaCount, betaCount]
        }

        let draft = try planner.makeDraft(text: source, timeline: nil)

        XCTAssertGreaterThanOrEqual(draft.chapters.count, 2)
        XCTAssertEqual(draft.chapters.first?.startChar, 0)
        XCTAssertEqual(draft.chapters.last?.endChar, source.trimmingCharacters(in: .whitespacesAndNewlines).count)
        XCTAssertTrue(zip(draft.chapters, draft.chapters.dropFirst()).allSatisfy { lhs, rhs in
            lhs.endChar <= rhs.startChar
        })
    }

    func testPlannerCarriesExactMediaNavigationAnchorsIntoDraft() throws {
        let firstText = String(repeating: "Opening ideas and context. ", count: 55)
        let secondText = String(repeating: "A distant topic and practical consequences. ", count: 55)
        let source = "\(firstText) \(secondText)"
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "segment-opening", startMs: 0, endMs: 240_000, startChar: 0, endChar: firstText.count, text: firstText),
                MediaTimelineSegment(id: "segment-pivot", startMs: 240_000, endMs: 480_000, startChar: firstText.count + 1, endChar: source.count, text: secondText)
            ],
            chapters: [],
            durationMs: 480_000
        )
        let planner = LocalListeningMapPlanner { text in
            text.contains("Opening") ? [1, 0] : [0, 1]
        }

        let draft = try planner.makeDraft(text: source, timeline: timeline)

        XCTAssertEqual(draft.chapters.first?.startMs, 0)
        XCTAssertEqual(draft.chapters.first?.transcriptSegmentId, "segment-opening")
        XCTAssertEqual(draft.chapters.last?.startMs, 240_000)
        XCTAssertEqual(draft.chapters.last?.transcriptSegmentId, "segment-pivot")
    }

    func testMapMetadataValidatorRejectsLongSourceQuotation() {
        let source = "one two three four five six seven eight nine ten eleven twelve"
        let label = LocalListeningMapLabel(
            title: "A short title",
            description: "one two three four five six seven eight nine ten"
        )

        XCTAssertThrowsError(try LocalListeningMapOutputValidator.validate(label: label, sourceText: source)) { error in
            XCTAssertEqual(error as? LocalFoundationModelError, .excessiveSourceQuotation)
        }
    }
}
