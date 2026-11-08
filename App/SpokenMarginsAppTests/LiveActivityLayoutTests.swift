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

    /// The card's own padding around its content.
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 10
    /// The narrowest Lock Screen's content width.
    private static let narrowestContentWidth: CGFloat = 311

    private static var columnLeft: CGFloat {
        narrowestCardWidth - horizontalPadding - Gate2ControlSize.marginColumnWidth
    }

    private static var columnCentre: CGFloat { columnLeft + Gate2ControlSize.marginColumnWidth / 2 }

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
        for card in [state(status: "playing"), state(status: "paused"), recordingState()] {
            let rendered = try render(card, size: .large)
            XCTAssertLessThanOrEqual(
                rendered.height, Self.lockScreenHeightLimit,
                "\(card.status) with a next chapter: the system may cut the card off"
            )
        }
    }

    /// The largest size before the accessibility range, where a playing card has to keep its controls. A paused card's
    /// extra prompt line passes the limit there, as it did before #3692; accessibility sizes are not held to it.
    func testAPlayingCardFitsTheLockScreenHeightAtTheLargestStandardTextSize() throws {
        let rendered = try render(state(status: "playing"), size: .xxxLarge)
        XCTAssertLessThanOrEqual(rendered.height, Self.lockScreenHeightLimit)
    }

    /// #3692: the circles and the Margin column share the narrowest Lock Screen, and no circle drops below 44 pt.
    func testTheCirclesAndTheMarginColumnFitTheNarrowestContentWidth() {
        XCTAssertLessThanOrEqual(
            Gate2ControlSize.transportRowWidth + Gate2ControlSize.marginColumnGap + Gate2ControlSize.marginColumnWidth,
            Self.narrowestContentWidth
        )
        for circle in [Gate2ControlSize.skim, Gate2ControlSize.skip, Gate2ControlSize.play] {
            XCTAssertGreaterThanOrEqual(circle, 44)
        }
    }

    /// #3692: the Margin control is 60 pt wide and runs the full height of the card's content, with nothing above it.
    func testTheMarginColumnRunsTheFullHeightOfTheCard() throws {
        for card in [state(status: "playing"), state(status: "paused"), recordingState()] {
            let image = try renderImage(card, size: .large)
            let middle = image.size.height / 2
            let rightEdge = Self.columnLeft + Gate2ControlSize.marginColumnWidth

            XCTAssertGreaterThanOrEqual(image.size.height - 2 * Self.verticalPadding, 88, "\(card.status): too short")
            XCTAssertTrue(try isFilled(image, x: Self.columnCentre, y: Self.verticalPadding + 2), "\(card.status): stops short of the top")
            XCTAssertTrue(
                try isFilled(image, x: Self.columnCentre, y: image.size.height - Self.verticalPadding - 2),
                "\(card.status): stops short of the bottom"
            )
            XCTAssertTrue(try isFilled(image, x: Self.columnLeft + 2, y: middle), "\(card.status): narrower on the left")
            XCTAssertTrue(try isFilled(image, x: rightEdge - 2, y: middle), "\(card.status): narrower on the right")
            XCTAssertFalse(try isFilled(image, x: Self.columnLeft - 2, y: middle), "\(card.status): the gap beside it is gone")
        }
    }

    /// Start and finish must differ without colour (#3692): solid white against a soft fill, and a squarer outline
    /// against a pill. Both are read as brightness, so the check holds for a red-green colourblind listener too.
    func testStartAndFinishDifferByFillAndOutline() throws {
        let start = try renderImage(state(status: "playing"), size: .large)
        let finish = try renderImage(recordingState(), size: .large)
        let cornerX = Self.columnLeft + 7
        let cornerY = Self.verticalPadding + 4

        XCTAssertLessThan(try red(start, x: Self.columnCentre, y: Self.verticalPadding + 2), 0.4, "start should be a soft fill")
        XCTAssertGreaterThan(try red(finish, x: Self.columnCentre, y: Self.verticalPadding + 2), 0.9, "finish should be solid white")
        XCTAssertFalse(try isFilled(start, x: cornerX, y: cornerY), "start should be a pill")
        XCTAssertTrue(try isFilled(finish, x: cornerX, y: cornerY), "finish should be squarer than the pill")
    }

    /// With no Margin to start, the column's space stays empty.
    func testNoMarginColumnWhenTheCommandIsUnavailable() throws {
        var card = state(status: "playing")
        card.availableCommands.removeAll { $0 == "beginInterjection" }
        let image = try renderImage(card, size: .large)
        XCTAssertFalse(try isFilled(image, x: Self.columnCentre, y: image.size.height - Self.verticalPadding - 4))
    }

    /// A Shared Margin's buttons take the full width: where the gap beside the column would be, Dismiss is drawn.
    func testASharedMarginTakesTheFullWidth() throws {
        var card = state(status: "playing")
        card.sharedMarginSenderLabel = "Sam"
        let image = try renderImage(card, size: .large)
        XCTAssertTrue(try isFilled(image, x: Self.columnLeft - 2, y: image.size.height - Self.verticalPadding - 19))
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

    private func recordingState() -> Gate2LiveActivityAttributes.ContentState {
        var card = state(status: "recording")
        card.isRecording = true
        card.availableCommands = Self.transportCommands.filter { $0 != "beginInterjection" } + ["finishInterjection"]
        return card
    }

    /// The card's background has a red channel of 0.08 and the softest control fill about 0.2.
    private func isFilled(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> Bool {
        try red(image, x: x, y: y) > 0.16
    }

    private func red(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> CGFloat {
        let cgImage = try XCTUnwrap(image.cgImage)
        let origin = CGRect(x: Int(x * image.scale), y: Int(y * image.scale), width: 1, height: 1)
        let pixel = try XCTUnwrap(cgImage.cropping(to: origin))
        var rgba = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(rgba[0]) / 255
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
