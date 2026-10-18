import Foundation
import XCTest
@testable import SessionKit

/// The prompts, decoders and safety-term rewrites for the on-device model's interjection summaries (moved from the app target, #318).
final class LocalInterjectionPromptsTests: XCTestCase {
    func testInterjectionSummaryPromptsUseOnlyOneNoteAndNeverSourceAnchors() {
        let record = LocalInterjectionSummaryRecord(
            id: "note-1",
            anchorBefore: "SECRET SOURCE BEFORE",
            anchorAfter: "SECRET SOURCE AFTER",
            note: "Maybe this matters"
        )
        let prompts = LocalInterjectionPrompts.interjectionSummaryPrompts(record: record)
        let synthesis = LocalInterjectionPrompts.interjectionSynthesisPrompt(
            record: record,
            drafts: ["Maybe it matters"]
        )
        let extraction = LocalInterjectionPrompts.interjectionPointExtractionPrompt(record: record)

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
        XCTAssertTrue(LocalInterjectionPrompts.interjectionPointExtractionInstructions.contains("one note, not theme synthesis"))
        XCTAssertTrue(LocalInterjectionPrompts.interjectionPointExtractionInstructions.contains("self-contained"))
        XCTAssertTrue(LocalInterjectionPrompts.interjectionPointExtractionInstructions.contains("source-supported"))
        XCTAssertFalse(extraction.contains("Extract the minimum number"))
        XCTAssertTrue(
            LocalInterjectionPrompts.interjectionPointCondensationInstructions(
                point: "Does this work?",
                wordLimit: 6
            ).contains("must remain a question")
        )
    }

    func testPermissiveTransformationInstructionsConstrainTaskToTextEditing() {
        let instructions = LocalInterjectionPrompts.interjectionPermissiveTransformationInstructions

        XCTAssertTrue(instructions.contains("text editing"))
        XCTAssertTrue(instructions.contains("not a request to carry out"))
        XCTAssertTrue(instructions.contains("Do not answer"))
    }

    func testGeoffreyInterjectionRepairsContextProvenDictationAndAuditsEveryClaim() {
        let source = "He is contradicting himself. He predicts a phase change, proposes training small models, and now relies on supervision. He cannot train models even close to the frontier at this tiny land, so he cannot play in the game given his mental model."

        XCTAssertEqual(
            LocalInterjectionSafetyTerms.repairContextProvenDictation(
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
        let points = try LocalInterjectionDecoder.decodePlainTextPoints("""
        ```json
        [
          "Confirm saving when closing.",
          "Remove the toast when opening."
        ]
        ```
        """)

        XCTAssertEqual(points, ["Confirm saving when closing.", "Remove the toast when opening."])
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodePlainTextPoints("not JSON"))
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodePlainTextPoints("[\"one\", \"two\", \"three\", \"four\"]"))

        let deduplicated = try LocalInterjectionDecoder.decodePlainTextPoints("""
        [
          "Does pausing immediately after playback starts prevent background activation?",
          "Does pausing immediately after playback start prevent background activation?"
        ]
        """)
        XCTAssertEqual(deduplicated.count, 1)
    }

    func testMeaningSlotDecoderPreservesActualFourSightQuestionAndAttributionPoints() throws {
        let source = "I wonder if she is a ideator and an implementer. Um, this is fine in a quote. We need to make sure this is not foresight saying this. This can totally be declare saying it."
        let points = try LocalInterjectionDecoder.decodeInterjectionMeaningSlots(
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
        let points = try LocalInterjectionDecoder.decodeInterjectionMeaningSlots(
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
        let safe = LocalInterjectionSafetyTerms.modelSafeInterjectionText(source)

        XCTAssertFalse(safe.lowercased().contains("misalignment"))
        XCTAssertFalse(safe.lowercased().contains("zero-day"))
        XCTAssertEqual(
            LocalInterjectionSafetyTerms.restoreSafetyTerms(in: safe),
            "misalignment can produce cheating near a zero-day security vulnerability before a model breaks the law."
        )
    }

    /// Every spoken term the model must not see, what it is swapped for, and what `restoreSafetyTerms` puts back.
    /// The restore is lossy on purpose: several spoken forms share one safe stand-in, so the listener's own
    /// wording comes back as the canonical term ("misaligned" returns as "misalignment").
    func testEverySafetyTermIsHiddenFromTheModelAndComesBackAsItsCanonicalForm() {
        let table: [(spoken: String, hiddenTerm: String, restored: String)] = [
            ("zero-day", "zero", "zero-day"),
            ("zero day", "zero", "zero-day"),
            ("0 day", "0", "zero-day"),
            ("security vulnerability", "vulnerab", "security vulnerability"),
            ("break the law", "law", "break the law"),
            ("do anything illegal", "illegal", "break the law"),
            ("illegal actions", "illegal", "break the law"),
            ("illegal action", "illegal", "break the law"),
            ("cheating", "cheat", "cheating"),
            ("cheat", "cheat", "cheat"),
            ("misalignment", "misalign", "misalignment"),
            ("misaligned", "misalign", "misalignment"),
            ("mislined", "mislined", "misalignment"),
            ("malicious", "malicious", "malicious"),
            ("super malicious", "malicious", "malicious")
        ]

        for row in table {
            let sentence = "The note says \(row.spoken) here."
            let safe = LocalInterjectionSafetyTerms.modelSafeInterjectionText(sentence)
            XCTAssertFalse(safe.lowercased().contains(row.hiddenTerm), "\(row.spoken) reached the model as: \(safe)")
            XCTAssertNotEqual(safe, sentence, "\(row.spoken) was not replaced")
            XCTAssertEqual(
                LocalInterjectionSafetyTerms.restoreSafetyTerms(in: safe),
                "The note says \(row.restored) here.",
                "\(row.spoken) did not restore to \(row.restored)"
            )
        }
    }

    func testEachSafetyTermBecomesItsOwnExactStandIn() {
        // The round trip above can hide a deleted rule behind a neighbouring one ("cheating" would still come back
        // through the "cheat" rule), so the stand-ins themselves are pinned.
        let standIns: [String: String] = [
            "zero-day": "verified issue Z",
            "security vulnerability": "verified system issue",
            "break the law": "violate a hard constraint",
            "do anything illegal": "violate a hard constraint",
            "cheating": "violating requirements",
            "cheat": "violate requirements",
            "misalignment": "goal drift",
            "super malicious": "strategically deceptive"
        ]
        for (spoken, standIn) in standIns {
            XCTAssertEqual(LocalInterjectionSafetyTerms.modelSafeInterjectionText(spoken), standIn, spoken)
        }
        XCTAssertEqual(LocalInterjectionSafetyTerms.modelSafeInterjectionText("0day and zeroday"), "verified issue Z and verified issue Z")
        XCTAssertEqual(LocalInterjectionSafetyTerms.modelSafeInterjectionText("Well, bullshit, fuck it."), "Well, , .")
    }

    func testDictationRepairsReachTheModelAndTheRestoreAcceptsTheModelsOwnWording() {
        XCTAssertEqual(LocalInterjectionSafetyTerms.modelSafeInterjectionText("We do the land at this tiny land."), "We do alignment at this tiny lab.")
        XCTAssertEqual(LocalInterjectionSafetyTerms.restoreSafetyTerms(in: "A requirements violation, two requirements violations."), "A cheating, two cheating.")
        XCTAssertEqual(LocalInterjectionSafetyTerms.restoreSafetyTerms(in: "Do not violate requirements."), "Do not cheat.")
        XCTAssertEqual(LocalInterjectionSafetyTerms.restoreSafetyTerms(in: "Verified Issue Z and GOAL DRIFT"), "zero-day and misalignment")
    }

    func testTheSafetyStandInsForSeveralSpokenFormsAreRestoredToOneCanonicalTerm() {
        XCTAssertEqual(
            LocalInterjectionSafetyTerms.modelSafeInterjectionText("misaligned"),
            LocalInterjectionSafetyTerms.modelSafeInterjectionText("misalignment"),
            "both spoken forms reach the model as the same stand-in"
        )
        XCTAssertEqual(
            LocalInterjectionSafetyTerms.restoreSafetyTerms(in: LocalInterjectionSafetyTerms.modelSafeInterjectionText("misaligned")),
            "misalignment",
            "the restore is lossy: the original wording is not kept"
        )
    }

    func testPartialSummaryReductionProducesStructuredListenerOnlyPayload() throws {
        let payload = try XCTUnwrap(LocalInterjectionDecoder.summaryPayload(from: """
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

    func testSummaryPayloadReadsEncodedJSONAndRejectsContextWithoutPartials() throws {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "v1",
            itemTitle: "Title",
            interjections: [LocalInterjectionSummaryRecord(id: "a", anchorBefore: "b", anchorAfter: "c", note: "d")]
        )
        let json = try String(decoding: JSONEncoder().encode(payload), as: UTF8.self)

        XCTAssertEqual(LocalInterjectionDecoder.summaryPayload(from: json), payload)
        XCTAssertNil(LocalInterjectionDecoder.summaryPayload(from: ""))
        XCTAssertNil(LocalInterjectionDecoder.summaryPayload(from: "PARTIAL 1:\n   \n"))
        XCTAssertNil(LocalInterjectionDecoder.summaryPayload(from: "just a sentence"))
    }

    func testPartialSummaryPayloadCapsEachNoteAndSkipsTextBeforeTheFirstHeader() throws {
        let payload = try XCTUnwrap(LocalInterjectionDecoder.summaryPayload(from: """
        preamble that is not a partial
        PARTIAL 1:
        \(String(repeating: "x", count: 2_000))
        PARTIAL 2:
        second
        """))

        XCTAssertEqual(payload.interjections.map(\.id), ["partial-1", "partial-2"])
        XCTAssertEqual(payload.interjections[0].note.count, 1_200)
        XCTAssertEqual(payload.interjections[1].note, "second")
    }

    func testLabelDecoderAcceptsFencedAndWrappedJSONAndRejectsText() throws {
        let fenced = try LocalInterjectionDecoder.decodeLabel("""
        ```json
        {"title": "Opening", "description": "The host sets up the topic."}
        ```
        """)
        XCTAssertEqual(fenced.title, "Opening")
        XCTAssertNil(fenced.eligibility)

        let wrapped = try LocalInterjectionDecoder.decodeLabel(
            "Here you go: {\"title\": \"Ad\", \"description\": \"A sponsor read.\", \"eligibility\": \"excluded\", \"eligibilityReason\": \"Sponsor read\"} Thanks."
        )
        XCTAssertEqual(wrapped.title, "Ad")
        XCTAssertEqual(wrapped.eligibility, .excluded)
        XCTAssertEqual(wrapped.eligibilityReason, "Sponsor read")

        XCTAssertThrowsError(try LocalInterjectionDecoder.decodeLabel("no label here"))
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodeLabel(""))
    }

    func testPlainTextPointDecoderRejectsEmptyAndWhitespaceOnlyLists() {
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodePlainTextPoints("[]"))
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodePlainTextPoints("[\"  \", \"\"]"))
        XCTAssertThrowsError(try LocalInterjectionDecoder.decodePlainTextPoints(""))
    }

    func testSafetyTermsAreCaseInsensitiveAndLeaveOrdinaryTextAlone() {
        XCTAssertEqual(LocalInterjectionSafetyTerms.modelSafeInterjectionText("Plain note about pacing."), "Plain note about pacing.")
        XCTAssertEqual(LocalInterjectionSafetyTerms.restoreSafetyTerms(in: "Plain note about pacing."), "Plain note about pacing.")
        let safe = LocalInterjectionSafetyTerms.modelSafeInterjectionText("ZERO DAY and Cheating")
        XCTAssertFalse(safe.lowercased().contains("zero"))
        XCTAssertFalse(safe.lowercased().contains("cheat"))
        XCTAssertEqual(LocalInterjectionSafetyTerms.restoreSafetyTerms(in: safe), "zero-day and cheating")
    }

    func testCondensationInstructionsOnlyDemandAQuestionForAQuestion() {
        XCTAssertFalse(
            LocalInterjectionPrompts.interjectionPointCondensationInstructions(point: "Ship it.", wordLimit: 6)
                .contains("must remain a question")
        )
        XCTAssertTrue(
            LocalInterjectionPrompts.interjectionPointCondensationInstructions(point: "Ship it?", wordLimit: 6)
                .contains("6 words or fewer")
        )
    }
}
