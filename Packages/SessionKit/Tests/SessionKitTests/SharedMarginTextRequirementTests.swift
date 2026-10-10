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

    /// #1185: one spoken Margin with no transcript and one written Margin, both included,
    /// used to read "2" on the Share button while the packet held 1.
    func testTheCountOnTheButtonIsTheCountInThePacket() {
        struct Draft { var included: Bool; var text: String }
        let drafts = [Draft(included: true, text: ""), Draft(included: true, text: "Second note for sharing")]
        let summary = SharedMarginSelectionSummary(drafts, isIncluded: { $0.included }, text: { $0.text })
        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.leftOutCount, 1)
        XCTAssertEqual(summary.notice, "1 Margin has no transcript and wasn't included.")
        // The packet is built from exactly this split (Gate1AppModel.exportSharePackage).
        let packet = SharedMarginTextRequirement.shareable(drafts.filter { $0.included }, text: { $0.text })
        XCTAssertEqual(packet.margins.count, summary.packetCount)
        XCTAssertEqual(packet.omission, summary.notice)
    }

    func testTheSummaryIgnoresMarginsTheListenerLeftOut() {
        struct Draft { var included: Bool; var text: String }
        let drafts = [
            Draft(included: false, text: ""), Draft(included: false, text: "Not chosen"),
            Draft(included: true, text: " \n"), Draft(included: true, text: "A"), Draft(included: true, text: "B"),
        ]
        let summary = SharedMarginSelectionSummary(drafts, isIncluded: { $0.included }, text: { $0.text })
        XCTAssertEqual(summary.packetCount, 2)
        XCTAssertEqual(summary.leftOutCount, 1)

        let none = SharedMarginSelectionSummary([Draft(included: true, text: "")], isIncluded: { $0.included }, text: { $0.text })
        XCTAssertEqual(none.packetCount, 0)
        XCTAssertEqual(none.notice, SharedMarginTextRequirement.omissionNotice(omitted: 1, remaining: 0))

        let empty = SharedMarginSelectionSummary([Draft](), isIncluded: { $0.included }, text: { $0.text })
        XCTAssertEqual(empty.packetCount, 0)
        XCTAssertNil(empty.notice)
    }

    /// The Share Margins count starts from the same Margins the sheet pre-selects (#1185 audit).
    func testTheSheetStartsWithOnlyStarredMarginsWhenAnyAreStarred() {
        func margin(_ id: String, starred: Bool?) -> Interjection {
            Interjection(
                id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "a", anchorAfter: "b"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                transcript: "Words for \(id).", cleanedTranscript: nil, displayText: nil, status: "active",
                isStarredForSharing: starred
            )
        }
        let plain = [margin("a", starred: nil), margin("b", starred: false)]
        XCTAssertEqual(SharedMarginTextRequirement.initiallyIncluded(plain).map(\.id), ["a", "b"])
        let mixed = plain + [margin("c", starred: true)]
        XCTAssertEqual(SharedMarginTextRequirement.initiallyIncluded(mixed).map(\.id), ["c"])
        XCTAssertEqual(SharedMarginTextRequirement.initialReviewedText(for: mixed[2]), "Words for c.")
    }
}
