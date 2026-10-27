import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import XCTest

/// #2130: the edges of placing a podcast Margin between two verified anchors. Removing the 10-minute span cap or the
/// speed band, or always borrowing the later anchor's offset, each left every test green (the 2026-10-19 audit).
final class PodcastAnchorInterpolationEdgeTests: XCTestCase {
    private typealias Resolver = PodcastAnchorFusionResolver

    /// Two verified anchors, `lower` and `upper` as (sender ms, recipient ms), and one unresolved Margin between them.
    private func place(
        lower: (sender: Int, recipient: Int), upper: (sender: Int, recipient: Int), marginAt sender: Int
    ) -> ImportedAnchorResolution? {
        let queries = [
            PodcastPortableAnchorQuery(packageScopedId: "lower", senderMediaTimeMs: lower.sender, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "margin", senderMediaTimeMs: sender, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "upper", senderMediaTimeMs: upper.sender, evidence: [])
        ]
        let result = Resolver.interpolatingBetweenVerifiedAnchors(queries: queries, resolutions: [
            "lower": .init(evidenceClass: .acousticVerified, localMediaTimeMs: lower.recipient, confidence: 0.9),
            "margin": .init(evidenceClass: .unresolved),
            "upper": .init(evidenceClass: .fused, localMediaTimeMs: upper.recipient, confidence: 1)
        ])
        return result["margin"]
    }

    private func assertPlaced(_ resolution: ImportedAnchorResolution?, at ms: Int, _ message: String, line: UInt = #line) {
        XCTAssertEqual(resolution?.evidenceClass, .mapInterpolated, message, line: line)
        XCTAssertEqual(resolution?.localMediaTimeMs, ms, message, line: line)
    }

    private func assertUnplaced(_ resolution: ImportedAnchorResolution?, _ message: String, line: UInt = #line) {
        XCTAssertEqual(resolution?.evidenceClass, .unresolved, message, line: line)
        XCTAssertNil(resolution?.localMediaTimeMs, message, line: line)
    }

    func testAMarginBetweenAnchorsMoreThanTenMinutesApartIsNotPlaced() {
        XCTAssertEqual(Resolver.maximumInterpolationSpanMs, 600_000)
        assertPlaced(place(lower: (0, 0), upper: (600_000, 600_000), marginAt: 300_000), at: 300_000,
                     "exactly ten minutes is allowed")
        assertUnplaced(place(lower: (0, 0), upper: (600_001, 600_001), marginAt: 300_000),
                       "one millisecond over the cap would put the Margin in a guessed minute")
        assertUnplaced(place(lower: (0, 0), upper: (3_600_000, 3_600_000), marginAt: 1_800_000), "an hour apart")
    }

    func testTheSpeedBandKeepsAStretchedOrSquashedStretchUnplaced() {
        XCTAssertEqual(Resolver.permittedInterpolationRate, 0.5...1.5)
        // Rate = recipient span / sender span.
        assertPlaced(place(lower: (0, 0), upper: (100_000, 50_000), marginAt: 20_000), at: 20_000, "0.5x is allowed")
        assertUnplaced(place(lower: (0, 0), upper: (100_000, 49_999), marginAt: 20_000), "just under 0.5x")
        assertPlaced(place(lower: (0, 0), upper: (100_000, 150_000), marginAt: 80_000), at: 130_000, "1.5x is allowed")
        assertUnplaced(place(lower: (0, 0), upper: (100_000, 150_001), marginAt: 80_000), "just over 1.5x")
        assertUnplaced(place(lower: (0, 0), upper: (100_000, 300_000), marginAt: 80_000), "3x: the stretch is not the same audio")
        assertUnplaced(place(lower: (0, 0), upper: (100_000, 10_000), marginAt: 20_000), "a tenth of the length")
    }

    func testAMarginTakesTheOffsetOfTheNearerAnchor() {
        // An ad of 10 s before the lower anchor, another 20 s between: offsets +10 s, then +30 s.
        let lower = (sender: 100_000, recipient: 110_000)
        let upper = (sender: 200_000, recipient: 230_000)
        assertPlaced(place(lower: lower, upper: upper, marginAt: 120_000), at: 130_000, "nearer the earlier anchor: its +10 s")
        assertPlaced(place(lower: lower, upper: upper, marginAt: 180_000), at: 210_000, "nearer the later anchor: its +30 s")
        assertPlaced(place(lower: lower, upper: upper, marginAt: 150_000), at: 160_000, "an exact tie goes to the earlier anchor")
        assertPlaced(place(lower: lower, upper: upper, marginAt: 150_001), at: 180_001, "one millisecond past the middle")
    }

    func testAPlacedMarginCarriesTheWeakerAnchorsConfidenceAndNeverLeavesTheAnchors() throws {
        let placed = place(lower: (100_000, 110_000), upper: (200_000, 230_000), marginAt: 120_000)
        XCTAssertEqual(try XCTUnwrap(placed?.confidence), 0.63, accuracy: 1e-9, "min(0.9, 1) x 0.7")
        // The nearer anchor's offset can carry a Margin onto or past the other anchor; that is refused, not clamped.
        let lower = (sender: 100_000, recipient: 200_000) // offset +100 s
        let upper = (sender: 200_000, recipient: 250_000) // offset +50 s
        assertPlaced(place(lower: lower, upper: upper, marginAt: 149_999), at: 249_999, "one millisecond short of the later anchor")
        assertUnplaced(place(lower: lower, upper: upper, marginAt: 150_000), "lands exactly on the later anchor's time")
    }
}
