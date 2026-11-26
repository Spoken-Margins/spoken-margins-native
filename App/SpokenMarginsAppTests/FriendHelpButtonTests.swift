import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class FriendHelpButtonTests: XCTestCase {
    /// The import sheet's missing-source notice sits in an `ExperienceSurface`, whose body text colour drew "Get Help"
    /// near-black there: it read as a line of text, not a button, while the failure sheet's drew in the accent (#5268,
    /// seen in PR #5300's look). This draws the button inside a surface and reads the colour of its letters.
    func testGetHelpKeepsTheAccentInsideAnExperienceSurface() throws {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let accent = try rgb(UIColor(AppColors.accent).resolvedColor(with: light))
        let text = try rgb(UIColor(AppColors.text).resolvedColor(with: light))
        let view = ExperienceSurface { FriendHelpButton {} }
            .frame(width: 320)
            .tint(AppColors.accent)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let pixels = try XCTUnwrap(renderer.cgImage.flatMap(Self.pixels), "the button did not draw")

        var nearAccent = 0
        var nearText = 0
        for pixel in pixels {
            let toAccent = distance(pixel, accent)
            let toText = distance(pixel, text)
            // Only the solid middle of each letter: edges blend into the panel and are near neither colour.
            guard min(toAccent, toText) < 0.08 else { continue }
            if toAccent < toText { nearAccent += 1 } else { nearText += 1 }
        }
        XCTAssertGreaterThan(nearAccent, 40, "Get Help drew \(nearAccent) accent pixels and \(nearText) body-text pixels")
        XCTAssertGreaterThan(nearAccent, nearText * 4, "Get Help drew \(nearAccent) accent pixels and \(nearText) body-text pixels")
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private func rgb(_ color: UIColor) throws -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        return (Double(r), Double(g), Double(b))
    }

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    /// The opaque pixels of `image` in sRGB.
    private static func pixels(_ image: CGImage) -> [RGB]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).compactMap { index in
            bytes[index + 3] == 255 ? (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255) : nil
        }
    }
}
