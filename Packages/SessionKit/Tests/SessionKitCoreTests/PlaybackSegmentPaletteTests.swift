import Foundation
@testable import SessionKit
import XCTest

/// The playback plate's two segmented controls read their colours from `PlaybackSegmentPalette`, and the contrast
/// audit measures the same numbers (#3735).
final class PlaybackSegmentPaletteTests: XCTestCase {
    private func ratio(_ name: String, _ appearance: String = "light") throws -> Double {
        let pair = try XCTUnwrap(AppColorContrastAudit.playbackSegmentPairs.first { $0.name == name }, name)
        let measurement = try XCTUnwrap(
            AppColorContrastAudit.measurements(for: [pair]).first { $0.appearance == appearance }, name)
        return measurement.ratio
    }

    func testThePaletteHoldsTheOpaqueWhitePillWithPlateGreenWords() {
        XCTAssertEqual(PlaybackSegmentPalette.trayAlpha, 0.06)
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedFillAlpha, 1)
        XCTAssertEqual(PlaybackSegmentPalette.filterSelectedFillAlpha, 1)
        XCTAssertEqual(PlaybackSegmentPalette.fill, AppSemanticColorRGB.white)
        XCTAssertEqual(PlaybackSegmentPalette.selectedLabel, AppSemanticColorRGB.listeningBackground)
        XCTAssertEqual(PlaybackSegmentPalette.unselectedLabel, AppSemanticColorRGB.white)
        XCTAssertEqual(PlaybackSegmentPalette.plate, AppSemanticColorRGB.listeningBackground)
    }

    func testTheTrayAndThePillsAreLayeredOverThePlateOneOverTheOther() {
        let plate = AppSemanticColorRGB.listeningBackground.light
        let tray = PlaybackSegmentPalette.tray.light
        XCTAssertEqual(tray, AppSemanticColorRGB.white.light.composited(over: plate, alpha: 0.06))
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedPill.light,
                       AppSemanticColorRGB.white.light.composited(over: tray, alpha: PlaybackSegmentPalette.paneSelectedFillAlpha))
        XCTAssertEqual(PlaybackSegmentPalette.filterSelectedPill.light,
                       AppSemanticColorRGB.white.light.composited(over: tray, alpha: PlaybackSegmentPalette.filterSelectedFillAlpha))
        // The plate is the same in both appearances, so the layers are too.
        XCTAssertEqual(PlaybackSegmentPalette.tray.light, PlaybackSegmentPalette.tray.dark)
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedPill.light, PlaybackSegmentPalette.paneSelectedPill.dark)
    }

    func testTheAuditNamesAllSixPairsAndEveryOneIsInTheWholeAudit() {
        let names = AppColorContrastAudit.playbackSegmentPairs.map(\.name)
        XCTAssertEqual(names, [
            "pane switch selected fill against tray", "pane switch selected label",
            "filter selected fill against tray", "filter selected label", "segment unselected label on tray",
            "segment selected bar on pill"
        ])
        XCTAssertEqual(Set(names).count, names.count)
        let all = Set(AppColorContrastAudit.allPairs.map(\.name))
        for name in names { XCTAssertTrue(all.contains(name), name) }
    }

    func testTheRatiosMatchTheNumbersTheDesignQuotes() throws {
        // Pill against tray: 10.54:1 (was 1.69 for the pane switch and 3.10 for the filter).
        XCTAssertEqual(try ratio("pane switch selected fill against tray"), 10.54, accuracy: 0.05)
        XCTAssertEqual(try ratio("filter selected fill against tray"), 10.54, accuracy: 0.05)
        // Plate green on white: 12.63:1 in both controls (the filter was 3.41).
        XCTAssertEqual(try ratio("pane switch selected label"), 12.63, accuracy: 0.05)
        XCTAssertEqual(try ratio("filter selected label"), 12.63, accuracy: 0.05)
        XCTAssertEqual(try ratio("segment selected bar on pill"), 12.63, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(try ratio("segment unselected label on tray"), 4.5)
    }

    func testNoSegmentPairFailsInEitherAppearanceAndNoneIsAKnownFailure() {
        let segmentNames = Set(AppColorContrastAudit.playbackSegmentPairs.map(\.name))
        let measurements = AppColorContrastAudit.measurements(for: AppColorContrastAudit.playbackSegmentPairs)
        XCTAssertEqual(measurements.count, segmentNames.count * 2, "every pair is measured light and dark")
        XCTAssertTrue(measurements.filter(\.fails).isEmpty)
        XCTAssertTrue(AppColorContrastAudit.knownFailures.filter { segmentNames.contains($0.pair) }.isEmpty,
                      "#3735 is fixed: its known failures are removed")
    }
}
