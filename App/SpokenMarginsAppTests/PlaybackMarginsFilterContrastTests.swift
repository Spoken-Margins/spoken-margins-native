import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #1923: the selected Margins filter was white at 18% over a 6% tray, about 1.7:1, so a sighted listener
/// couldn't tell which segment was on. The fill now reaches 3:1 against the tray (WCAG 1.4.11).
@MainActor
final class PlaybackMarginsFilterContrastTests: XCTestCase {
    func testTheSelectedFilterSegmentReachesThreeToOneAgainstTheTray() throws {
        let image = try render(selection: .mine)
        // The pixel positions below only mean something on the 360 x 60 canvas this test draws.
        XCTAssertEqual([image.width, image.height], [360, 60], "the render is not the size the pixel positions assume")
        // 360 pt wide, 4 pt tray padding, three segments with 4 pt gaps: "Mine" spans about x 123 to 237.
        let selected = try XCTUnwrap(luminance(of: image, x: 130, y: 26))
        let tray = try XCTUnwrap(luminance(of: image, x: 2, y: 26))
        let ratio = (selected + 0.05) / (tray + 0.05)
        // Name both pixels so a failure on a hosted run says which one was off, not only the ratio (#2970).
        XCTAssertGreaterThanOrEqual(
            ratio, 3, "Selected segment is \(ratio):1 against the tray (selected \(selected), tray \(tray), image \(image.width) x \(image.height))"
        )
    }

    private func render(selection: PlaybackMarginsList.Filter) throws -> CGImage {
        let view = ZStack {
            Color.black
            PlaybackMarginsFilterView(selection: .constant(selection))
        }
        .frame(width: 360, height: 60)
        .environment(\.colorScheme, .dark)
        // The filter lays out as a column at accessibility text sizes, which would move "Mine" off the sampled pixel.
        // Pin the size so the render doesn't depend on the simulator's or an earlier test's text setting (#2970).
        .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    /// WCAG relative luminance of one pixel, read through an sRGB bitmap so the format doesn't matter.
    private func luminance(of image: CGImage, x: Int, y: Int) -> Double? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(pixel[0]) + 0.7152 * linear(pixel[1]) + 0.0722 * linear(pixel[2])
    }
}
