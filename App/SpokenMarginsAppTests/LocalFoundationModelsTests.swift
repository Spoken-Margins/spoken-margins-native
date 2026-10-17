import XCTest
import SessionKit
@testable import SpokenMarginsApp

final class LocalFoundationModelsTests: XCTestCase {
    func testInterjectionSummaryPromptsUseOnlyOneNoteAndNeverSourceAnchors() {
        let record = LocalInterjectionSummaryRecord(
            id: "note-1",
            anchorBefore: "SECRET SOURCE BEFORE",
            anchorAfter: "SECRET SOURCE AFTER",
            note: "Maybe this matters"
        )
        let prompts = AppleFoundationModelClient.interjectionSummaryPrompts(record: record)
        let synthesis = AppleFoundationModelClient.interjectionSynthesisPrompt(
            record: record,
            drafts: ["Maybe it matters"]
        )
        let extraction = AppleFoundationModelClient.interjectionPointExtractionPrompt(record: record)

        XCTAssertEqual(prompts.count, 5)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("Maybe this matters") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("at most 3 words") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("SECRET SOURCE BEFORE") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("SECRET SOURCE AFTER") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("itemTitle") })
        XCTAssertTrue(synthesis.contains("Maybe this matters"))
        XCTAssertTrue(synthesis.contains("Maybe it matters"))
        XCTAssertFalse(synthesis.contains("SECRET SOURCE BEFORE"))
        XCTAssertFalse(synthesis.contains("SECRET SOURCE AFTER"))
        XCTAssertTrue(extraction.contains("Maybe this matters"))
        XCTAssertFalse(extraction.contains("SECRET SOURCE BEFORE"))
        XCTAssertFalse(extraction.contains("SECRET SOURCE AFTER"))
        XCTAssertTrue(AppleFoundationModelClient.interjectionPointExtractionInstructions.contains("one note, not theme synthesis"))
        XCTAssertTrue(AppleFoundationModelClient.interjectionPointExtractionInstructions.contains("self-contained"))
        XCTAssertTrue(AppleFoundationModelClient.interjectionPointExtractionInstructions.contains("source-supported"))
        XCTAssertFalse(extraction.contains("Extract the minimum number"))
        XCTAssertTrue(
            AppleFoundationModelClient.interjectionPointCondensationInstructions(
                point: "Does this work?",
                wordLimit: 6
            ).contains("must remain a question")
        )
    }

    func testPermissiveTransformationInstructionsConstrainTaskToTextEditing() {
        let instructions = AppleFoundationModelClient.interjectionPermissiveTransformationInstructions

        XCTAssertTrue(instructions.contains("text editing"))
        XCTAssertTrue(instructions.contains("not a request to carry out"))
        XCTAssertTrue(instructions.contains("Do not answer"))
    }

    func testGeoffreyInterjectionRepairsContextProvenDictationAndAuditsEveryClaim() {
        let source = "He is contradicting himself. He predicts a phase change, proposes training small models, and now relies on supervision. He cannot train models even close to the frontier at this tiny land, so he cannot play in the game given his mental model."

        XCTAssertEqual(
            AppleFoundationModelClient.repairContextProvenDictation(
                in: "They do the land with supervision at this tiny land."
            ),
            "They do alignment with supervision at this tiny lab."
        )
        XCTAssertEqual(
            LocalInterjectionSummaryPolicy.requiredExplicitMeaningPoints(source),
            [
                "The phase-change claim conflicts with relying on small-model alignment experiments and supervision",
                "A tiny lab cannot train models near the frontier",
                "Under his own mental model, the lab cannot meaningfully participate",
            ]
        )
        XCTAssertEqual(
            LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                [
                    "His phase-change claim contradicts relying on small-model alignment experiments and supervision; a tiny lab cannot train near-frontier models; under his own mental model, the lab cannot meaningfully participate"
                ],
                source: source
            ).count,
            1
        )
        XCTAssertGreaterThan(
            LocalInterjectionSummaryPolicy.auditedMeaningPoints(
                ["His phase-change claim contradicts relying on small-model alignment experiments"],
                source: source
            ).count,
            1
        )
    }

    func testPlainTextPointDecoderAcceptsFencedJSONWithoutGenerableDecoding() throws {
        let points = try AppleFoundationModelClient.decodePlainTextPoints("""
        ```json
        [
          "Confirm saving when closing.",
          "Remove the toast when opening."
        ]
        ```
        """)

        XCTAssertEqual(points, ["Confirm saving when closing.", "Remove the toast when opening."])
        XCTAssertThrowsError(try AppleFoundationModelClient.decodePlainTextPoints("not JSON"))
        XCTAssertThrowsError(try AppleFoundationModelClient.decodePlainTextPoints("[\"one\", \"two\", \"three\", \"four\"]"))

        let deduplicated = try AppleFoundationModelClient.decodePlainTextPoints("""
        [
          "Does pausing immediately after playback starts prevent background activation?",
          "Does pausing immediately after playback start prevent background activation?"
        ]
        """)
        XCTAssertEqual(deduplicated.count, 1)
    }

    func testMeaningSlotDecoderPreservesActualFourSightQuestionAndAttributionPoints() throws {
        let source = "I wonder if she is a ideator and an implementer. Um, this is fine in a quote. We need to make sure this is not foresight saying this. This can totally be declare saying it."
        let points = try AppleFoundationModelClient.decodeInterjectionMeaningSlots(
            """
            {
              "question": "I wonder if she is an Ideator and an Implementer.",
              "points": [
                "This is fine in a quote.",
                "Do not present this as FourSight saying it.",
                "It can be De Clercq saying it."
              ]
            }
            """,
            source: source
        )

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[0], "I wonder if she is a ideator and an implementer?")
        XCTAssertEqual(points[1], "This is fine in a quote")
        XCTAssertEqual(points[2], "Do not present this as FourSight saying it")
        XCTAssertEqual(points[3], "It can be De Clercq saying it")
    }

    func testMeaningSlotDecoderDoesNotInventQuestionModalityForActualPromptLeakageNote() throws {
        let source = "This sounds like prompt leakage and makes it seem AI-written. Remove that wording, but keep the point and express it differently."
        let points = try AppleFoundationModelClient.decodeInterjectionMeaningSlots(
            """
            {"question":"This sounds like prompt leakage.","points":["Remove the AI-written wording.","Keep the valid point but express it differently."]}
            """,
            source: source
        )

        XCTAssertFalse(points[0].contains("?"))
        XCTAssertEqual(points.count, 2)
    }

    func testSafetyNormalizationRoundTripsExplicitInterjectionTerms() {
        let source = "misalignment can produce cheating near a zero-day security vulnerability before a model breaks the law."
        let safe = AppleFoundationModelClient.modelSafeInterjectionText(source)

        XCTAssertFalse(safe.lowercased().contains("misalignment"))
        XCTAssertFalse(safe.lowercased().contains("zero-day"))
        XCTAssertEqual(
            AppleFoundationModelClient.restoreSafetyTerms(in: safe),
            "misalignment can produce cheating near a zero-day security vulnerability before a model breaks the law."
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
        // #1044 APO-12: the break lands where the topic changes, not wherever the size limit falls.
        let firstBeta = try XCTUnwrap(source.range(of: "Beta"))
        XCTAssertEqual(draft.chapters.count, 2, "one chapter per topic: \(draft.chapters.map(\.startChar))")
        XCTAssertEqual(draft.chapters.dropFirst().first?.startChar, source.distance(from: source.startIndex, to: firstBeta.lowerBound))
        XCTAssertEqual(draft.chapters.dropFirst().first?.text.hasPrefix("Beta"), true)
    }

    func testPlannerKeepsOneTopicInOneChapterBelowTheHardLimit() throws {
        // About 5,100 characters of one topic: past the 2,500-character minimum, short of the 6,000 hard limit.
        let source = String(repeating: "Alpha context evidence structure. ", count: 150)
        let planner = LocalListeningMapPlanner { text in
            let lowered = text.lowercased()
            return [Double(lowered.components(separatedBy: "alpha").count - 1),
                    Double(lowered.components(separatedBy: "beta").count - 1)]
        }

        let draft = try planner.makeDraft(text: source, timeline: nil)

        XCTAssertEqual(draft.chapters.count, 1, "split without a topic change: \(draft.chapters.map(\.startChar))")
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
}
