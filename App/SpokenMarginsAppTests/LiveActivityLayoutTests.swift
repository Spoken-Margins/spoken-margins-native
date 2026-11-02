import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #1940: the Lock Screen card's control row came to about 420 pt, wider than the Lock Screen, and the fit of the
/// fix was arithmetic. These tests lay the real card out at the narrowest Lock Screen width, at the default text
/// size and at the largest one, and attach each rendering so a run's result bundle holds the screenshots.
@MainActor
final class LiveActivityLayoutTests: XCTestCase {
    /// The Live Activity's width on a 375 pt-wide phone, the narrowest iOS 26 runs on (16 pt of it is the card's own
    /// padding on each side).
    private static let narrowestCardWidth: CGFloat = 343
    /// The system may cut off a Lock Screen Live Activity taller than this.
    private static let lockScreenHeightLimit: CGFloat = 160

    private static let transportCommands = [
        "skimBackward", "skipBack", "togglePlayPause", "skipForward", "skimForward", "beginInterjection",
    ]

    private func state(status: String) -> Gate2LiveActivityAttributes.ContentState {
        Gate2LiveActivityAttributes.ContentState(
            title: "The Long Title of an Episode That Runs Past One Line",
            chapterTitle: "Chapter 4: A Chapter Title Long Enough to Need Shrinking",
            nextChapterTitle: "Chapter 5: What Comes Next",
            nextChapterId: "chapter-5",
            nextNavigationKind: .sourceChapter,
            status: status,
            phase: "itemPlayback",
            progressPercent: 42,
            isRecording: false,
            availableCommands: Self.transportCommands,
            skimForwardDestinationMs: 3_725_000,
            skimBackwardDestinationMs: 3_605_000
        )
    }

    func testTheControlRowFitsTheNarrowestLockScreenAtEveryTextSize() throws {
        for status in ["playing", "paused"] {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
                let rendered = try render(state(status: status), size: size)
                XCTAssertLessThanOrEqual(
                    rendered.width, Self.narrowestCardWidth + 0.5,
                    "\(status) at \(size): the card is wider than the Lock Screen, so a control is cut off"
                )
            }
        }
    }

    func testTheCardFitsTheLockScreenHeightAtTheDefaultTextSize() throws {
        for status in ["playing", "paused"] {
            let rendered = try render(state(status: status), size: .large)
            XCTAssertLessThanOrEqual(
                rendered.height, Self.lockScreenHeightLimit,
                "\(status) with a next chapter: the system may cut the card off"
            )
        }
    }

    /// #1508: the owner saw the card's progress bar out of step with playback and asked for it to go. If any pixel of
    /// the card still follows `progressPercent`, a card at 5% and one at 95% would differ.
    func testTheCardShowsNoPlaybackProgress() throws {
        for status in ["playing", "paused"] {
            var early = state(status: status)
            early.progressPercent = 5
            var late = state(status: status)
            late.progressPercent = 95
            let earlyPNG = try XCTUnwrap(try renderImage(early, size: .large).pngData())
            let latePNG = try XCTUnwrap(try renderImage(late, size: .large).pngData())
            XCTAssertEqual(earlyPNG, latePNG, "\(status): the card still draws playback progress")
        }
    }

    private func render(_ state: Gate2LiveActivityAttributes.ContentState, size: DynamicTypeSize) throws -> CGSize {
        try renderImage(state, size: size).size
    }

    private func renderImage(_ state: Gate2LiveActivityAttributes.ContentState, size: DynamicTypeSize) throws -> UIImage {
        let card = Gate2LiveActivityView(state: state, isStale: false)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.08, green: 0.09, blue: 0.12))
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: Self.narrowestCardWidth, height: nil)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "the card did not render")
        let attachment = XCTAttachment(image: image)
        attachment.name = "live-activity-\(state.status)-\(size)-\(Int(image.size.width))x\(Int(image.size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}
