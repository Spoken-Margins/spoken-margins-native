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

    func testThePaletteHoldsTheValuesTheViewsDrewBeforeTheAuditSawThem() {
        XCTAssertEqual(PlaybackSegmentPalette.trayAlpha, 0.06)
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedFillAlpha, 0.18)
        XCTAssertEqual(PlaybackSegmentPalette.filterSelectedFillAlpha, 0.40)
        XCTAssertEqual(PlaybackSegmentPalette.fill, AppSemanticColorRGB.white)
        XCTAssertEqual(PlaybackSegmentPalette.selectedLabel, AppSemanticColorRGB.white)
        XCTAssertEqual(PlaybackSegmentPalette.unselectedLabel, AppSemanticColorRGB.white)
        XCTAssertEqual(PlaybackSegmentPalette.plate, AppSemanticColorRGB.listeningBackground)
    }

    func testTheTrayAndThePillsAreLayeredOverThePlateOneOverTheOther() {
        let plate = AppSemanticColorRGB.listeningBackground.light
        let tray = PlaybackSegmentPalette.tray.light
        XCTAssertEqual(tray, AppSemanticColorRGB.white.light.composited(over: plate, alpha: 0.06))
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedPill.light,
                       AppSemanticColorRGB.white.light.composited(over: tray, alpha: 0.18))
        XCTAssertEqual(PlaybackSegmentPalette.filterSelectedPill.light,
                       AppSemanticColorRGB.white.light.composited(over: tray, alpha: 0.40))
        // The plate is the same in both appearances, so the layers are too.
        XCTAssertEqual(PlaybackSegmentPalette.tray.light, PlaybackSegmentPalette.tray.dark)
        XCTAssertEqual(PlaybackSegmentPalette.paneSelectedPill.light, PlaybackSegmentPalette.paneSelectedPill.dark)
    }

    func testTheAuditNamesAllFivePairsAndEveryOneIsInTheWholeAudit() {
        let names = AppColorContrastAudit.playbackSegmentPairs.map(\.name)
        XCTAssertEqual(names, [
            "pane switch selected fill against tray", "pane switch selected label",
            "filter selected fill against tray", "filter selected label", "segment unselected label on tray"
        ])
        XCTAssertEqual(Set(names).count, names.count)
        let all = Set(AppColorContrastAudit.allPairs.map(\.name))
        for name in names { XCTAssertTrue(all.contains(name), name) }
    }

    func testTodaysRatiosMatchTheNumbersTheDesignQuotes() throws {
        XCTAssertEqual(try ratio("pane switch selected fill against tray"), 1.69, accuracy: 0.02)
        XCTAssertEqual(try ratio("filter selected label"), 3.41, accuracy: 0.02)
        XCTAssertEqual(try ratio("filter selected fill against tray"), 3.10, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(try ratio("pane switch selected label"), 4.5)
        XCTAssertGreaterThanOrEqual(try ratio("segment unselected label on tray"), 4.5)
    }

    func testExactlyTheTwoFailingPairsAreKnownFailuresInEachAppearance() {
        let segmentNames = Set(AppColorContrastAudit.playbackSegmentPairs.map(\.name))
        let failing = Set(AppColorContrastAudit.measurements(for: AppColorContrastAudit.playbackSegmentPairs)
            .filter(\.fails).map { "\($0.pair)|\($0.appearance)" })
        let known = Set(AppColorContrastAudit.knownFailures.filter { segmentNames.contains($0.pair) }
            .map { "\($0.pair)|\($0.appearance)" })
        XCTAssertEqual(failing, [
            "pane switch selected fill against tray|light", "pane switch selected fill against tray|dark",
            "filter selected label|light", "filter selected label|dark"
        ])
        XCTAssertEqual(known, failing, "A known failure that passes, or a failure that is not known, fails the audit")
        XCTAssertTrue(AppColorContrastAudit.knownFailures.filter { segmentNames.contains($0.pair) }
            .allSatisfy { $0.fixedBy == "#3735" })
    }
}
