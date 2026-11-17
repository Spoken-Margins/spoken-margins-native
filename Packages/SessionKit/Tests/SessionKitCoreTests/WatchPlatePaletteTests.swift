import XCTest
@testable import SessionKit

/// #3731: the Watch's plates read their colours from `WatchPlatePalette`, and the contrast audit measures the same numbers.
final class WatchPlatePaletteTests: XCTestCase {
    private func ratio(_ pairName: String) throws -> Double {
        let pair = try XCTUnwrap(AppColorContrastAudit.watchPlatePairs.first { $0.name == pairName }, "no pair named \(pairName)")
        return try XCTUnwrap(AppColorContrastAudit.measurements(for: [pair]).first).ratio
    }

    func testEveryPlateHasItsLabelAndPressedPair() {
        let names = Set(AppColorContrastAudit.watchPlatePairs.map(\.name))
        for plate in WatchPlate.allCases {
            XCTAssertTrue(names.contains("watch \(plate.rawValue) plate label"), "\(plate)")
            XCTAssertTrue(names.contains("watch \(plate.rawValue) plate label, pressed"), "\(plate)")
        }
        XCTAssertTrue(names.contains("watch episode header text"))
        XCTAssertTrue(names.contains("watch session header text"))
        XCTAssertEqual(names.count, AppColorContrastAudit.watchPlatePairs.count, "pair names are unique")
    }

    func testEveryWatchPlatePairPasses() {
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.watchPlatePairs), [])
    }

    /// The numbers the Design quotes, so a palette change that loses margin is seen.
    func testTheLabelsKeepTheirMargin() throws {
        XCTAssertEqual(try ratio("watch session plate label"), 8.04, accuracy: 0.05)
        XCTAssertEqual(try ratio("watch episode plate label"), 5.76, accuracy: 0.05)
        XCTAssertEqual(try ratio("watch record plate label"), 5.76, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(try ratio("watch session plate label, pressed"), 5.2 - 0.05)
        XCTAssertGreaterThanOrEqual(try ratio("watch episode plate label, pressed"), 5.2 - 0.05)
    }

    func testStopDrawsTheTargetsPlate() {
        XCTAssertEqual(WatchPlatePalette.stopPlate(for: nil), .session, "no target was shown: the session plate")
        XCTAssertEqual(WatchPlatePalette.stopPlate(for: .episode), .episode)
        XCTAssertEqual(WatchPlatePalette.stopPlate(for: .session), .session)
        // Only the two target plates are a recording's target; anything else falls back to the session plate.
        XCTAssertEqual(WatchPlatePalette.stopPlate(for: .discard), .session)
    }

    /// The deep blue is a fill; as text on black it is 3.64:1, so the header keeps the bright blue.
    func testTheEpisodeHeaderIsNotTheFill() {
        XCTAssertNotEqual(WatchPlatePalette.headerText(.episode), WatchPlatePalette.fill(.episode).color)
    }

    /// Two plate colours are copies of tokens, because the Watch does not compile the token file.
    func testTheCopiedColoursMatchTheirTokens() {
        func rgb(_ c: WatchPlateColor) -> AppColorRGB { AppColorRGB(red: c.red, green: c.green, blue: c.blue) }
        XCTAssertEqual(rgb(WatchPlatePalette.label(.session)), AppSemanticColorRGB.watchBackground.dark)
        XCTAssertEqual(rgb(WatchPlatePalette.fill(.discard).color), AppSystemColorRGB.red.dark)
        XCTAssertEqual(rgb(WatchPlatePalette.fill(.session).color), AppSystemColorRGB.orange.dark)
    }

    func testAPressedPlateStillShowsThePress() {
        XCTAssertLessThan(WatchPlatePalette.pressedMultiplier, 1)
        XCTAssertGreaterThan(WatchPlatePalette.pressedMultiplier, 0.6, "0.6 put the dark words on orange at 3.14:1")
    }
}
