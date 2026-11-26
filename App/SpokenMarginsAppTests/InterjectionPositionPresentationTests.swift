import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

final class InterjectionPositionPresentationTests: XCTestCase {
    func testKnownDurationOverridesStaleStoredZeroPercent() {
        let interjection = mediaInterjection(mediaTimeMs: 225_000, roughPercent: 0)

        XCTAssertEqual(InterjectionPositionPresentation.percent(for: interjection, durationMs: 900_000), 25)
        XCTAssertEqual(InterjectionPositionPresentation.timelineBadge(for: interjection, durationMs: 900_000), "25%")
        XCTAssertEqual(
            InterjectionPositionPresentation.detailDescription(for: interjection, durationMs: 900_000),
            "3:45 · around 25%"
        )
    }

    func testUnknownDurationUsesDurableTimestampInsteadOfFalseZeroPercent() {
        let interjection = mediaInterjection(mediaTimeMs: 225_000, roughPercent: 0)

        XCTAssertNil(InterjectionPositionPresentation.percent(for: interjection, durationMs: nil))
        XCTAssertEqual(InterjectionPositionPresentation.timelineBadge(for: interjection, durationMs: nil), "3:45")
        XCTAssertEqual(InterjectionPositionPresentation.detailDescription(for: interjection, durationMs: nil), "3:45")
    }

    /// #4233: a Margin moved from a live session with no place stores zeros. Every position wording says "No place"
    /// and never "0%" or "0:00", and the Margins-tab row's place line says it with the day.
    func testAMarginWithNoPlaceNeverReadsAsAZeroPercentOrClock() {
        var interjection = mediaInterjection(mediaTimeMs: 0, roughPercent: 0)
        interjection.movedOrigin = MovedMarginOrigin(
            marginId: interjection.id, itemId: interjection.itemId, sessionId: interjection.sessionId,
            liveMarginId: "live-1", fromLiveSessionId: "live", fromLiveSessionTitle: "Quick session",
            markedAt: interjection.createdAt, movedAt: interjection.createdAt, placeKnown: false)

        XCTAssertNil(InterjectionPositionPresentation.percent(for: interjection, durationMs: 900_000))
        XCTAssertEqual(InterjectionPositionPresentation.timelineBadge(for: interjection, durationMs: 900_000), "No place")
        XCTAssertEqual(InterjectionPositionPresentation.detailDescription(for: interjection, durationMs: 900_000), "No place saved")
        XCTAssertEqual(InterjectionPositionPresentation.timelineBadge(for: interjection, durationMs: nil), "No place")

        let row = MarginRow(interjection: interjection, itemTitle: "Source", sessionDate: nil)
        XCTAssertTrue(row.placeDescription(now: interjection.createdAt).hasPrefix("No place · "), row.placeDescription())
        XCTAssertFalse(row.placeDescription(now: interjection.createdAt).contains("0%"))
        XCTAssertFalse(row.placeDescription(now: interjection.createdAt).contains("0:00"))
    }

    private func mediaInterjection(mediaTimeMs: Int, roughPercent: Int) -> Interjection {
        Interjection(
            id: "ij-media",
            itemId: "item-media",
            sessionId: "session-media",
            targetType: .item,
            targetId: "item-media",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: roughPercent,
            anchor: Anchor(
                anchorType: .media,
                startChar: 0,
                endChar: 0,
                anchorBefore: "",
                anchorAfter: "",
                mediaTimeMs: mediaTimeMs
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "complete",
            transcript: "A note.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
    }
}
