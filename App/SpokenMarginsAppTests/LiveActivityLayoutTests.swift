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
        for card in [state(status: "playing"), state(status: "paused")] + lockScreenCards {
            for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
                let rendered = try render(card, size: size)
                XCTAssertLessThanOrEqual(
                    rendered.width, Self.narrowestCardWidth + 0.5,
                    "\(describe(card)) at \(size): the card is wider than the Lock Screen, so a control is cut off"
                )
            }
        }
    }

    func testTheCardFitsTheLockScreenHeightAtTheDefaultTextSize() throws {
        for card in [state(status: "playing"), state(status: "paused"), recordingState()] + lockScreenCards {
            let rendered = try render(card, size: .large)
            XCTAssertLessThanOrEqual(
                rendered.height, Self.lockScreenHeightLimit,
                "\(describe(card)) with a next chapter: the system may cut the card off"
            )
        }
    }

    /// Every card keeps its controls through the largest size before the accessibility range. The paused prompt shares
    /// the chapter line, so a paused card is held to the same limit as a playing one (#3692).
    func testEveryCardFitsTheLockScreenHeightThroughTheLargestStandardTextSize() throws {
        for card in [state(status: "playing"), state(status: "paused"), recordingState()] + lockScreenCards {
            for size in [DynamicTypeSize.xLarge, .xxLarge, .xxxLarge] {
                let rendered = try render(card, size: size)
                XCTAssertLessThanOrEqual(
                    rendered.height, Self.lockScreenHeightLimit, "\(describe(card)) at \(size): the system may cut the card off"
                )
            }
        }
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

    /// #4764: the Margin control is a fixed 60 pt circle centred in its column, on every card the Lock Screen really
    /// gets. The card is often only a header tall, and a pill that took the card's height squashed its caption there.
    func testTheMarginCircleIsCentredInTheColumn() throws {
        for card in lockScreenCards {
            let image = try renderImage(card, size: .large)
            let middle = image.size.height / 2
            let name = describe(card)

            XCTAssertGreaterThanOrEqual(
                image.size.height - 2 * Self.verticalPadding, Gate2ControlSize.marginColumnWidth, "\(name): the circle is cut"
            )
            XCTAssertTrue(try isFilled(image, x: Self.columnCentre, y: middle - 22), "\(name): no circle at the column's middle")
            XCTAssertFalse(try isFilled(image, x: Self.columnLeft + 3, y: middle - 27), "\(name): a corner is drawn, not a circle")
            XCTAssertFalse(try isFilled(image, x: Self.columnLeft - 2, y: middle), "\(name): the gap beside it is gone")
        }
        // The tallest real card: a shape that followed the card's height would fill the column's top.
        let skims = try renderImage(startWithSkims, size: .large)
        XCTAssertFalse(
            try isFilled(skims, x: Self.columnCentre, y: Self.verticalPadding + 4), "a pill above the circle: it follows the card's height"
        )
    }

    /// Start and finish must differ without colour (#3692, #4764): a soft fill with a bright ring against a solid white
    /// disc, and the microphone against the checkmark. Both are read as brightness, so the check holds for a red-green
    /// colourblind listener too.
    func testStartAndFinishDifferByFillAndRing() throws {
        let start = try renderImage(startNoSkims, size: .large)
        let finish = try renderImage(recordingOnLockScreen, size: .large)
        let startMiddle = start.size.height / 2
        let finishMiddle = finish.size.height / 2

        XCTAssertLessThan(try red(start, x: Self.columnCentre, y: startMiddle - 22), 0.4, "start should be a soft fill")
        XCTAssertGreaterThan(try red(finish, x: Self.columnCentre, y: finishMiddle - 22), 0.9, "finish should be solid white")
        XCTAssertGreaterThan(try red(start, x: Self.columnCentre, y: startMiddle - 29), 0.6, "start should have its ring")
    }

    /// #4764: nothing is written under the glyph. The band is where "Margin" and "Finish" sat; the glyph reaches about
    /// 13 pt from the centre and the ring starts at 28 pt.
    func testNoCaptionUnderTheMarginGlyph() throws {
        for (card, finishes) in [(startNoSkims, false), (recordingOnLockScreen, true)] {
            let image = try renderImage(card, size: .large)
            let pixels = try PixelBuffer(image)
            let middle = image.size.height / 2
            var marks = 0
            for y in stride(from: middle + 18, through: middle + 24, by: 0.5) {
                for x in stride(from: Self.columnCentre - 12, through: Self.columnCentre + 12, by: 0.5) {
                    let red = pixels.red(x: x, y: y)
                    if finishes ? red < 0.4 : red > 0.6 { marks += 1 }
                }
            }
            XCTAssertEqual(marks, 0, "\(describe(card)): something is drawn under the glyph")
        }
    }

    /// #4764: at the largest text size the glyph stops growing at AX1, so it stays inside the ring.
    func testTheMarginGlyphStaysInsideTheRingAtTheLargestTextSize() throws {
        let image = try renderImage(startNoSkims, size: .accessibility5)
        let middle = image.size.height / 2
        XCTAssertLessThan(try red(image, x: Self.columnCentre - 24, y: middle), 0.4, "the glyph reaches the ring on the left")
        XCTAssertLessThan(try red(image, x: Self.columnCentre + 24, y: middle), 0.4, "the glyph reaches the ring on the right")
        XCTAssertGreaterThan(try red(image, x: Self.columnCentre, y: middle - 29), 0.6, "the ring is gone")
    }

    /// With no Margin to start, the column's space stays empty.
    func testNoMarginColumnWhenTheCommandIsUnavailable() throws {
        var card = state(status: "playing")
        card.availableCommands.removeAll { $0 == "beginInterjection" }
        let image = try renderImage(card, size: .large)
        XCTAssertFalse(try isFilled(image, x: Self.columnCentre, y: image.size.height / 2))
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

    // The cards the Lock Screen really gets. Its policy keeps only start and finish Margin and the two skims, and drops
    // the skims while recording (`Gate2CompactControlController.swift:108-119, 622-626`), so it never shows the five
    // transport circles of `state(status:)` (#4764).
    private var lockScreenCards: [Gate2LiveActivityAttributes.ContentState] {
        [startNoSkims, startWithSkims, recordingOnLockScreen]
    }

    private var startNoSkims: Gate2LiveActivityAttributes.ContentState {
        var card = state(status: "playing")
        card.availableCommands = ["beginInterjection"]
        card.skimForwardDestinationMs = nil
        card.skimBackwardDestinationMs = nil
        return card
    }

    private var startWithSkims: Gate2LiveActivityAttributes.ContentState {
        var card = state(status: "playing")
        card.availableCommands = ["skimBackward", "skimForward", "beginInterjection"]
        return card
    }

    private var recordingOnLockScreen: Gate2LiveActivityAttributes.ContentState {
        var card = state(status: "recording")
        card.isRecording = true
        card.availableCommands = ["finishInterjection"]
        card.skimForwardDestinationMs = nil
        card.skimBackwardDestinationMs = nil
        return card
    }

    private func describe(_ card: Gate2LiveActivityAttributes.ContentState) -> String {
        "\(card.status) [\(card.availableCommands.joined(separator: ", "))]"
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

    /// The image's pixels read once, for a scan over many points.
    private struct PixelBuffer {
        let width: Int
        let height: Int
        let scale: CGFloat
        let rgba: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            scale = image.scale
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            rgba = bytes
        }

        /// Row 0 is the top: a bitmap context drawn this way keeps the image's own row order in memory.
        func red(x: CGFloat, y: CGFloat) -> CGFloat {
            let column = min(max(Int(x * scale), 0), width - 1)
            let row = min(max(Int(y * scale), 0), height - 1)
            return CGFloat(rgba[(row * width + column) * 4]) / 255
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
