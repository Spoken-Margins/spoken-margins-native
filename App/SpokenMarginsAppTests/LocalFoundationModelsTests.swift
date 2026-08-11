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
        XCTAssertTrue(AppleFoundationModelClient.interjectionPointExtractionInstructions.contains("Preserve questions as questions"))
        XCTAssertTrue(AppleFoundationModelClient.interjectionPointExtractionInstructions.contains("transformation requirement"))
        XCTAssertFalse(extraction.contains("Extract the minimum number"))
        XCTAssertTrue(
            AppleFoundationModelClient.interjectionPointCondensationInstructions(
                point: "Does this work?",
                wordLimit: 6
            ).contains("must remain a question")
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

    func testUncoveredTermsCollapseInflectionsAndExcludePriorMeaning() {
        let terms = LocalInterjectionSummaryPolicy.uncoveredTerms(
            in: "Fail loudly when failing to summarize claims.",
            excluding: "Summarize the claims."
        )

        XCTAssertEqual(terms, ["fail", "loudly"])
        XCTAssertGreaterThanOrEqual(
            LocalInterjectionSummaryPolicy.semanticOverlapRatio(
                "Fail loudly while summarizing claims",
                with: "Summarize the claims"
            ),
            0.40
        )
    }

    func testSpokenNoteCleanupRemovesFillersAndRepeatedWordsWithoutRemovingUncertainty() {
        let cleaned = LocalInterjectionSummaryPolicy.cleanSpokenNote(
            "So, uhm, I, I think that, ahh, um, maybe this is a good test."
        )

        XCTAssertEqual(cleaned, "Maybe this is a good test")
        XCTAssertEqual(
            LocalInterjectionSummaryPolicy.cleanModelCandidate("Does pausing prevent background playback?"),
            "Does pausing prevent background playback?"
        )
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
            bullets: ["Uhm, maybe this tests whether clipped posts remain understandable."],
            payload: payload
        ))
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["I think that, you know, maybe this tests whether clipped posts remain understandable."],
            payload: payload
        ))
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["The listener thinks clipped posts should remain understandable."],
            payload: payload
        ))
        XCTAssertEqual(
            try LocalInterjectionSummaryPolicy.validate(
                bullets: ["Clipped posts may remain understandable."],
                payload: payload
            ),
            ["Clipped posts may remain understandable."]
        )
    }

    func testSummaryValidationRejectsLightlyCleanedTranscriptInsteadOfCompressedIntent() {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Moving Forward from Hot Fable Summer",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "note-1",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: "I, um, think that, well, you know, that there's a lot of good points that they're making here. And I think their best one is that the strength of America is its relationship with middle powers and abandoning them significantly weakens us."
                )
            ]
        )

        XCTAssertEqual(LocalInterjectionSummaryPolicy.summaryWordLimit(for: 41), 21)
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["There's a lot of good points that they're making here, and their best one is that America's strength is its relationship with middle powers and abandoning them significantly weakens us."],
            payload: payload
        ))
        XCTAssertNoThrow(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["America's strongest advantage is its relationships with middle powers; abandoning them would significantly weaken the country."],
            payload: payload
        ))
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["There's a lot of good points that they're making here and their best one is America's relationship with middle powers."],
            payload: payload
        ))
    }

    func testSummaryValidationNeverExpandsShortNotesOrAcceptsTranscriptEquivalentText() {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Source",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "note-1",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: "Maybe this actually matters"
                )
            ]
        )

        XCTAssertEqual(LocalInterjectionSummaryPolicy.summaryWordLimit(for: 4), 4)
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Maybe this actually matters"],
            payload: payload
        ))
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Maybe this issue actually matters now"],
            payload: payload
        ))
        XCTAssertEqual(
            try LocalInterjectionSummaryPolicy.validate(
                bullets: ["Maybe it matters"],
                payload: payload
            ),
            ["Maybe it matters"]
        )
    }

    func testBestCandidateRejectsTranscriptCleanupAndSelectsConciseCoveredRewrite() throws {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Source",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "note-1",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: "I think opening a session does not need a toast because the navigation is already visually obvious, but closing should confirm that the session was saved."
                )
            ]
        )

        let best = try LocalInterjectionSummaryPolicy.bestCandidate(
            from: [
                "Summary: Opening a session does not need a toast because the navigation is already visually obvious, but closing should confirm that the session was saved.",
                "Opening needs no toast; closing should confirm the session was saved.",
                "Navigation works."
            ],
            payload: payload
        )

        XCTAssertEqual(best, "Opening needs no toast; closing should confirm the session was saved")
    }

    func testSummaryValidationPreservesQuestionsAndRejectsLowCoverageHallucination() {
        let questionPayload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Source",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "question",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: "Maybe I'm missing something, but does pausing immediately after playback starts prevent the audio session from becoming active in the background?"
                )
            ]
        )
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Pause playback to prevent background audio session activation."],
            payload: questionPayload
        ))
        XCTAssertNoThrow(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Does pausing playback prevent background audio session activation?"],
            payload: questionPayload
        ))

        let safetyPayload = LocalInterjectionSummaryPayload(
            schemaVersion: "local-interjection-summary.v1",
            itemTitle: "Source",
            interjections: [
                LocalInterjectionSummaryRecord(
                    id: "safety",
                    anchorBefore: "",
                    anchorAfter: "",
                    note: "The article discusses unsafe AI behavior, and I want the concise claim to preserve that risk without copying the surrounding source text."
                )
            ]
        )
        XCTAssertThrowsError(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["AI systems need updated safety protocols."],
            payload: safetyPayload
        ))
        XCTAssertNoThrow(try LocalInterjectionSummaryPolicy.validate(
            bullets: ["Preserve the article's unsafe-AI risk without copying surrounding source text."],
            payload: safetyPayload
        ))
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
