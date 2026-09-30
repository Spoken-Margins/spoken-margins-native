import Foundation
import XCTest
@testable import SessionKit

/// Tapping a shared Margin plays it at the best known position, and says when that's a guess (#158).
final class SharedMarginPlaybackPositionTests: XCTestCase {
    private func margin(senderMs: Int?, _ resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "imported-1", layerId: "layer-1", packageScopedId: "pkg::ij-002",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: senderMs),
            approvedTranscript: "Nice job, Joe.", resolution: resolution
        )
    }

    func testAVerifiedMatchInTheRecipientsCopyWins() {
        let position = SharedMarginPlaybackPosition(margin(
            senderMs: 302_926, .init(evidenceClass: .acousticVerified, localMediaTimeMs: 332_900)
        ))
        XCTAssertEqual(position, .init(mediaTimeMs: 332_900, isApproximate: false))
    }

    func testANeighbourInterpolatedMatchIsUsedButMarkedApproximate() {
        let position = SharedMarginPlaybackPosition(margin(
            senderMs: 302_926, .init(evidenceClass: .mapInterpolated, localMediaTimeMs: 322_900)
        ))
        XCTAssertEqual(position, .init(mediaTimeMs: 322_900, isApproximate: true))
    }

    func testAnUnmatchedOrAmbiguousMarginFallsBackToTheSendersTimeAsApproximate() {
        XCTAssertEqual(SharedMarginPlaybackPosition(margin(senderMs: 302_926, .init(evidenceClass: .unresolved))),
                       .init(mediaTimeMs: 302_926, isApproximate: true))
        let ambiguous = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 900_000, isAmbiguous: true)
        XCTAssertEqual(SharedMarginPlaybackPosition(margin(senderMs: 302_926, ambiguous)),
                       .init(mediaTimeMs: 302_926, isApproximate: true), "an ambiguous match is not a position")
    }

    func testNoPositionWithoutAMatchOrASenderTime() {
        XCTAssertNil(SharedMarginPlaybackPosition(margin(senderMs: nil, .init(evidenceClass: .unresolved))))
    }
}
