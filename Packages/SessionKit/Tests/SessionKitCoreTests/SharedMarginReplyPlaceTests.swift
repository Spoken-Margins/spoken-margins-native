import Foundation
import XCTest
@testable import SessionKit

/// Where a reply to a shared Margin sends the source before recording (#473). The audit of #1570 found that an
/// article or PDF Margin, anchored to text, had no place at all, so Reply never showed.
final class SharedMarginReplyPlaceTests: XCTestCase {
    private func margin(senderMs: Int? = nil, _ resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "imported-1", layerId: "layer-1", packageScopedId: "pkg::ij-002",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: senderMs == nil ? .text : .media, mediaTimeMs: senderMs),
            approvedTranscript: "A thought.", resolution: resolution
        )
    }

    func testAnArticleMarginMatchedInTheListenersTextRepliesAtThatPassage() {
        let place = SharedMarginReplyPlace(margin(.init(evidenceClass: .articleTextVerified, localStartChar: 1_200, localEndChar: 1_260)))
        XCTAssertEqual(place, .text(charOffset: 1_200))
    }

    func testAPassageAtTheStartOfTheTextIsAPlace() {
        XCTAssertEqual(SharedMarginReplyPlace(margin(.init(evidenceClass: .articleTextVerified, localStartChar: 0))), .text(charOffset: 0))
    }

    func testAPodcastMarginKeepsItsTimeAndAMediaTimeWinsOverText() {
        XCTAssertEqual(SharedMarginReplyPlace(margin(.init(evidenceClass: .exactEdition, localMediaTimeMs: 33_000))), .media(timeMs: 33_000))
        let both = ImportedAnchorResolution(evidenceClass: .exactEdition, localStartChar: 40, localMediaTimeMs: 5_000)
        XCTAssertEqual(SharedMarginReplyPlace(margin(both)), .media(timeMs: 5_000))
    }

    func testAnUnmatchedPodcastMarginStillFallsBackToTheSendersTime() {
        XCTAssertEqual(SharedMarginReplyPlace(margin(senderMs: 302_926, .init(evidenceClass: .unresolved))), .media(timeMs: 302_926))
    }

    func testNoPlaceWhenTheTextWasNotMatchedOrIsAmbiguous() {
        let neighbours: [ImportedAnchorResolution] = [
            .init(evidenceClass: .articleTextVerified),
            .init(evidenceClass: .articleTextVerified, localStartChar: -1),
            .init(evidenceClass: .articleTextVerified, localStartChar: 300, isAmbiguous: true),
            .init(evidenceClass: .unresolved, localStartChar: 300),
            .init(evidenceClass: .absentFromRecipientEdition, localStartChar: 300),
            .init(evidenceClass: .ambiguous, localStartChar: 300, isAmbiguous: true),
        ]
        for resolution in neighbours {
            XCTAssertNil(SharedMarginReplyPlace(margin(resolution)), "\(resolution.evidenceClass) \(String(describing: resolution.localStartChar))")
        }
    }
}
