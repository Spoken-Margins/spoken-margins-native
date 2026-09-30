import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest

/// A voice Margin whose transcription failed has good audio but no words (#304).
final class SharedMarginTextRequirementTests: XCTestCase {
    func testAPacketCannotCarryAVoiceMarginWithoutWords() throws {
        // The rule the share flow works around: Build 29's reader rejects an empty
        // transcript too, so this can't be relaxed without breaking compatibility.
        let audio = FileManager.default.temporaryDirectory.appending(path: "margin-\(UUID().uuidString).m4a")
        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "voice-without-words",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/essay", title: "Essay"),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-0001",
                revision: InterjectionShareRevision(
                    id: "revision-voice", interjectionId: "note", itemId: "item",
                    sessionId: "session", createdAt: Date(timeIntervalSince1970: 1_777_000_000), approvedTranscript: "  ",
                    anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
                ),
                anchor: .init(anchorType: .text, startChar: 0, endChar: 1),
                representation: .originalAudio(sourceURL: audio, durationMs: 4_000)
            )]
        )) { error in
            guard case InterjectionPackagePreparationError.emptyApprovedTranscript = error else {
                return XCTFail("Expected emptyApprovedTranscript, got \(error)")
            }
        }
    }

    func testOnlyMarginsWithWordsCanBeShared() {
        XCTAssertFalse(SharedMarginTextRequirement.hasReviewedText(""))
        XCTAssertFalse(SharedMarginTextRequirement.hasReviewedText(" \n "))
        XCTAssertTrue(SharedMarginTextRequirement.hasReviewedText("Remember this line."))
    }

    func testLeavingMarginsOutIsAlwaysSaid() {
        XCTAssertNil(SharedMarginTextRequirement.omissionNotice(omitted: 0, remaining: 5))
        XCTAssertNil(SharedMarginTextRequirement.omissionNotice(omitted: 0, remaining: 0))
        XCTAssertEqual(SharedMarginTextRequirement.omissionNotice(omitted: 1, remaining: 4), "1 Margin has no transcript and wasn't included.")
        XCTAssertEqual(SharedMarginTextRequirement.omissionNotice(omitted: 3, remaining: 2), "3 Margins have no transcript and weren't included.")
        XCTAssertEqual(
            SharedMarginTextRequirement.omissionNotice(omitted: 1, remaining: 0),
            "The selected Margin has no transcript yet, so there's nothing to share. Retry its transcription in Margin detail."
        )
        XCTAssertEqual(
            SharedMarginTextRequirement.omissionNotice(omitted: 2, remaining: 0),
            "None of the selected Margins has a transcript yet, so there's nothing to share. Retry their transcription in Margin detail."
        )
    }

    func testAMarginWithoutWordsIsWarnedAboutInReview() {
        XCTAssertEqual(SharedMarginTextRequirement.reviewWarning(for: "  "), SharedMarginTextRequirement.reviewWarningText)
        XCTAssertNil(SharedMarginTextRequirement.reviewWarning(for: "Remember this line."))
    }

    func testSharingSplitsOutMarginsWithoutWordsAndSaysSo() {
        let selected = ["First thought.", "", "Second thought.", " "]
        let (margins, omission) = SharedMarginTextRequirement.shareable(selected, text: { $0 })
        XCTAssertEqual(margins, ["First thought.", "Second thought."])
        XCTAssertEqual(omission, "2 Margins have no transcript and weren't included.")

        let (none, reason) = SharedMarginTextRequirement.shareable([""], text: { $0 })
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(reason, SharedMarginTextRequirement.omissionNotice(omitted: 1, remaining: 0))

        let (all, quiet) = SharedMarginTextRequirement.shareable(["Only thought."], text: { $0 })
        XCTAssertEqual(all, ["Only thought."])
        XCTAssertNil(quiet)
    }
}
