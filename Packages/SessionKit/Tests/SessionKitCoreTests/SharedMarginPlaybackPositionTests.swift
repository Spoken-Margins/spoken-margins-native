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

    // MARK: The whole table (PKT-08 of the #1039 audit)
    //
    // The cases above use two of the eleven evidence classes. This walks all of them against every shape of local
    // and sender time. The groups below are written out by hand, not read from the production `switch`, so moving
    // a class between groups fails here: a timestamp guess shown as a verified placement would make the app present
    // a guess as a placement.

    private let exactClasses: [AnchorResolutionEvidenceClass] = [
        .exactEdition, .transcriptVerified, .acousticVerified, .fused, .recipientConfirmed
    ]
    private let approximateClasses: [AnchorResolutionEvidenceClass] = [.mapInterpolated, .timestampFallback]
    private let senderOnlyClasses: [AnchorResolutionEvidenceClass] = [
        .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved
    ]
    private let localTimes: [Int?] = [nil, 0, 5_000, -1]
    private let senderTimes: [Int?] = [nil, 0, 7_000, -1]

    /// What the sender's time gives when the recipient's copy gives nothing usable.
    private func senderFallback(_ senderMs: Int?) -> SharedMarginPlaybackPosition? {
        guard let senderMs, senderMs >= 0 else { return nil }
        return .init(mediaTimeMs: senderMs, isApproximate: true)
    }

    func testTheClassGroupsCoverAllElevenEvidenceClasses() {
        let all = exactClasses + approximateClasses + senderOnlyClasses
        XCTAssertEqual(all.count, 11)
        XCTAssertEqual(Set(all.map(\.rawValue)).count, 11, "no class is listed twice")
        // Pins the eleven raw values the groups stand for. A class added to the enum is not caught here; whoever
        // adds one has to put it in a group above and extend this list.
        XCTAssertEqual(Set(all.map(\.rawValue)), [
            "exact_edition", "article_text_verified", "transcript_verified", "acoustic_verified", "fused",
            "map_interpolated", "timestamp_fallback", "recipient_confirmed", "ambiguous",
            "absent_from_recipient_edition", "unresolved"
        ])
    }

    func testVerifiedClassesPlayWhereTheRecipientMatchedAndAreNotApproximate() {
        for evidenceClass in exactClasses {
            for local in localTimes {
                for sender in senderTimes {
                    let position = SharedMarginPlaybackPosition(margin(senderMs: sender, .init(evidenceClass: evidenceClass, localMediaTimeMs: local)))
                    if let local, local >= 0 {
                        XCTAssertEqual(position, .init(mediaTimeMs: local, isApproximate: false), "\(evidenceClass) local \(local) sender \(String(describing: sender))")
                    } else {
                        XCTAssertEqual(position, senderFallback(sender), "\(evidenceClass) with no usable local time falls back to the sender, as a guess (local \(String(describing: local)) sender \(String(describing: sender)))")
                    }
                }
            }
        }
    }

    func testGuessClassesPlayWhereTheyPointButAreAlwaysApproximate() {
        for evidenceClass in approximateClasses {
            for local in localTimes {
                for sender in senderTimes {
                    let position = SharedMarginPlaybackPosition(margin(senderMs: sender, .init(evidenceClass: evidenceClass, localMediaTimeMs: local)))
                    if let local, local >= 0 {
                        XCTAssertEqual(position, .init(mediaTimeMs: local, isApproximate: true), "\(evidenceClass) local \(local) sender \(String(describing: sender))")
                    } else {
                        XCTAssertEqual(position, senderFallback(sender), "\(evidenceClass) local \(String(describing: local)) sender \(String(describing: sender))")
                    }
                }
            }
        }
    }

    func testClassesWithoutAMediaPlacementIgnoreALocalTimeAndUseTheSendersAsAGuess() {
        for evidenceClass in senderOnlyClasses {
            for local in localTimes {
                for sender in senderTimes {
                    let position = SharedMarginPlaybackPosition(margin(senderMs: sender, .init(evidenceClass: evidenceClass, localMediaTimeMs: local)))
                    XCTAssertEqual(position, senderFallback(sender), "\(evidenceClass) local \(String(describing: local)) sender \(String(describing: sender))")
                }
            }
        }
    }

    func testALocalTimeOfZeroIsAPlacementNotAMissingOne() {
        let position = SharedMarginPlaybackPosition(margin(senderMs: 7_000, .init(evidenceClass: .exactEdition, localMediaTimeMs: 0)))
        XCTAssertEqual(position, .init(mediaTimeMs: 0, isApproximate: false))
    }

    func testAnAmbiguousMatchIsNeverAPositionWhateverItsClass() {
        for evidenceClass in exactClasses + approximateClasses {
            let ambiguous = ImportedAnchorResolution(evidenceClass: evidenceClass, localMediaTimeMs: 900_000, isAmbiguous: true)
            XCTAssertEqual(SharedMarginPlaybackPosition(margin(senderMs: 7_000, ambiguous)),
                           .init(mediaTimeMs: 7_000, isApproximate: true), "\(evidenceClass)")
            XCTAssertNil(SharedMarginPlaybackPosition(margin(senderMs: nil, ambiguous)), "\(evidenceClass)")
        }
    }
}
