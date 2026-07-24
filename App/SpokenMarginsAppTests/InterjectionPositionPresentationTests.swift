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
