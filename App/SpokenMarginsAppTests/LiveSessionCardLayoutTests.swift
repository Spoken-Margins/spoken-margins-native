import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #3722: the live session's Lock Screen card had no Dynamic Type limits, so at accessibility sizes the Write and Speak
/// links row, or a button, could be cut off by the 160 pt the Lock Screen allows. These tests lay the real card out at
/// every text size at the narrowest Lock Screen width, and attach each rendering so a run's result bundle holds the
/// screenshots (the AX5 ones are the check the issue asks for).
@MainActor
final class LiveSessionCardLayoutTests: XCTestCase {
    /// The Live Activity's width on a 375 pt-wide phone, the narrowest iOS 26 runs on.
    private static let narrowestCardWidth: CGFloat = 343
    /// The system may cut off a Lock Screen Live Activity taller than this.
    private static let lockScreenHeightLimit: CGFloat = 160

    private static let sizes: [DynamicTypeSize] = [
        .xSmall, .large, .xLarge, .xxLarge, .xxxLarge,
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
    ]

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func cards() -> [(name: String, state: LiveSessionActivityAttributes.ContentState)] {
        [
            ("running", LiveSessionActivityAttributes.ContentState(markCount: 12, clockTitle: "Quarterly planning meeting, with a long clock name", sessionId: "s")),
            // A paper book or other session: three short capsules (#2708).
            ("running-photo", LiveSessionActivityAttributes.ContentState(markCount: 12, clockTitle: "Quarterly planning meeting, with a long clock name", sessionId: "s", offersPhoto: true)),
            ("recording", LiveSessionActivityAttributes.ContentState(markCount: 12, clockTitle: "Quarterly planning meeting, with a long clock name", sessionId: "s", isRecordingMargin: true)),
            ("ended", LiveSessionActivityAttributes.ContentState(markCount: 12, sessionId: "s", endedAt: start, resumeUntil: start.addingTimeInterval(600))),
        ]
    }

    func testEveryCardFitsTheLockScreenHeightAndWidthAtEveryTextSize() throws {
        for card in cards() {
            for size in Self.sizes {
                let rendered = try render(card.state, name: card.name, size: size)
                XCTAssertLessThanOrEqual(
                    rendered.height, Self.lockScreenHeightLimit,
                    "\(card.name) at \(size): the system may cut the card off"
                )
                XCTAssertLessThanOrEqual(
                    rendered.width, Self.narrowestCardWidth + 0.5, "\(card.name) at \(size): wider than the Lock Screen"
                )
            }
        }
    }

    /// The links row is what grows the running card past the limit, so it goes when text grows, and only then.
    func testTheMarginLinksGoAsTextGrows() throws {
        let running = try XCTUnwrap(cards().first { $0.name == "running" }).state
        let withLinks = try render(running, name: "running", size: .large)
        let atAX5 = try render(running, name: "running", size: .accessibility5)
        XCTAssertGreaterThan(withLinks.height, atAX5.height, "the links row should be gone at AX5")
        let xLarge = try render(running, name: "running", size: .xLarge)
        let xxLarge = try render(running, name: "running", size: .xxLarge)
        XCTAssertGreaterThan(xLarge.height, xxLarge.height, "the links row should be gone from xxLarge")
        XCTAssertTrue(LiveSessionCardLayout.showsMarginLinks(at: .large))
        XCTAssertFalse(LiveSessionCardLayout.showsMarginLinks(at: .xxxLarge))
        for size in Self.sizes where size.isAccessibilitySize {
            XCTAssertFalse(LiveSessionCardLayout.showsMarginLinks(at: size), "\(size)")
        }
    }

    /// Photo adds a capsule, not a row: the card is as tall as the plain one, and the third capsule is as wide as the
    /// others share out, so it neither pushes the card past 160 pt nor changes when the row drops (#2708).
    func testThePhotoCardIsNoTallerThanThePlainOneAndDropsItsRowWithIt() throws {
        let plain = try XCTUnwrap(cards().first { $0.name == "running" }).state
        let photo = try XCTUnwrap(cards().first { $0.name == "running-photo" }).state
        for size in Self.sizes {
            let a = try render(plain, name: "running", size: size)
            let b = try render(photo, name: "running-photo", size: size)
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(size)")
        }
    }

    /// An accessibility size reads the same as the ceiling: the card does not keep growing.
    func testTheCardStopsGrowingAtTheCeiling() throws {
        let running = try XCTUnwrap(cards().first { $0.name == "recording" }).state
        let ceiling = try render(running, name: "recording", size: LiveSessionCardLayout.textCeiling)
        let ax5 = try render(running, name: "recording", size: .accessibility5)
        XCTAssertEqual(ceiling.height, ax5.height, accuracy: 0.5)
        // Text does scale up to the ceiling, so equal heights above it come from the clamp.
        let xLarge = try render(running, name: "recording", size: .xLarge)
        XCTAssertGreaterThan(ceiling.height, xLarge.height)
    }

    private func render(
        _ state: LiveSessionActivityAttributes.ContentState, name: String, size: DynamicTypeSize
    ) throws -> CGSize {
        let card = LiveSessionActivityCard(state: state, sessionStartedAt: start, isStale: false)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: Self.narrowestCardWidth, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "the card did not render")
        let attachment = XCTAttachment(image: image)
        attachment.name = "live-session-card-\(name)-\(size)-\(Int(image.size.width))x\(Int(image.size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image.size
    }
}
