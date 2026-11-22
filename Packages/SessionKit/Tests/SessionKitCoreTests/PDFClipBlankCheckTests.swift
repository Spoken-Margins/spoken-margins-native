@testable import SessionKit
import XCTest

/// Which 64 x 64 grayscale crops are an empty piece of paper and which are a picture (#4587).
final class PDFClipBlankCheckTests: XCTestCase {
    private let side = 64

    private func field(_ value: UInt8) -> [UInt8] { Array(repeating: value, count: side * side) }

    func testAllWhiteIsBlank() {
        XCTAssertTrue(PDFClipBlankCheck.isBlank(luminance: field(255)))
    }

    func testCreamPaperIsBlank() {
        XCTAssertTrue(PDFClipBlankCheck.isBlank(luminance: field(245)))
    }

    func testWhiteWithATenthOfAPercentOfDarkSpecksIsBlank() {
        var pixels = field(255)
        for index in 0..<4 { pixels[index * 1000] = 0 }                  // 4 of 4096 pixels, about 0.1%
        XCTAssertTrue(PDFClipBlankCheck.isBlank(luminance: pixels))
    }

    func testEightDifferingPixelsStillCountAsBlankAndNineDoNot() {
        var pixels = field(255)
        for index in 0..<8 { pixels[index * 100] = 0 }
        XCTAssertTrue(PDFClipBlankCheck.isBlank(luminance: pixels), "0.2% of 4096 is 8.19 pixels")
        pixels[900] = 0
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: pixels))
    }

    func testThinPlotLinesCoveringTwoPercentOfAWhiteFieldAreNotBlank() {
        var pixels = field(255)
        // One 1-pixel horizontal line across the 64-wide crop is 64 pixels, 1.6%; two are 3.1%. Use a line and a bit.
        for x in 0..<side { pixels[10 * side + x] = 40 }
        for x in 0..<20 { pixels[30 * side + x] = 40 }                   // 84 pixels in all, about 2%
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: pixels))
    }

    func testAllBlackIsNotBlank() {
        // What a transparent page gives when it is not filled white first; the renderer fills white, so black is a
        // picture or a mistake that must not be dropped as paper.
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: field(0)))
    }

    func testAFlatMidGreyPanelIsNotBlank() {
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: field(128)))
    }

    func testAGreyGradientIsNotBlank() {
        let pixels = (0..<side * side).map { UInt8(($0 % side) * 255 / (side - 1)) }
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: pixels))
    }

    func testAPhotoLikeRandomFieldIsNotBlank() {
        var generator = SplitMix(seed: 4587)
        let pixels = (0..<side * side).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
        XCTAssertFalse(PDFClipBlankCheck.isBlank(luminance: pixels))
    }

    func testNoValuesIsBlank() {
        XCTAssertTrue(PDFClipBlankCheck.isBlank(luminance: []))
    }
}

/// A small deterministic generator, so the random field is the same on every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
