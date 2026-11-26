import Foundation
@testable import SessionKit
import XCTest

/// The Timeline rows' fill, stroke and label colours come from `TimelineRowPalette`, and the contrast audit generates
/// its row pairs from the same palette (#3734).
final class TimelineRowPaletteTests: XCTestCase {
    func testEveryRowIsAPanelCardAndTheCurrentRowIsTheHighlightedCard() {
        for kind in TimelineRowKind.allCases {
            XCTAssertEqual(TimelineRowPalette.fill(kind: kind, isCurrent: false),
                           .init(token: "panel", color: AppSemanticColorRGB.panel, alpha: 1), "\(kind)")
            XCTAssertEqual(TimelineRowPalette.fill(kind: kind, isCurrent: true),
                           .init(token: "softGreen", color: AppSemanticColorRGB.softGreen, alpha: 1), "\(kind)")
        }
        XCTAssertEqual(TimelineRowPalette.currentLabelColor, AppSemanticColorRGB.evergreen)
    }

    func testStrokesCarryTheKindAndOnlyTheAssistantsIsDashed() {
        for kind in TimelineRowKind.allCases {
            let stroke = TimelineRowPalette.stroke(kind: kind, isCurrent: false)
            XCTAssertEqual(stroke.color, TimelineRowPalette.labelColor(kind: kind), "\(kind)")
            XCTAssertEqual(stroke.width, 1)
            XCTAssertEqual(stroke.dashed, kind == .assistantResponse)
            XCTAssertEqual(stroke.alpha, kind == .assistantResponse ? 0.55 : 0.5)
            // The current row, of any kind, has one outline: opaque evergreen, 2 pt, solid.
            XCTAssertEqual(TimelineRowPalette.stroke(kind: kind, isCurrent: true),
                           .init(color: AppSemanticColorRGB.evergreen, alpha: 1, width: 2, dashed: false), "\(kind)")
        }
        XCTAssertEqual(TimelineRowPalette.labelColor(kind: .userResponse), AppSemanticColorRGB.ochreText)
    }

    func testEveryKindHasATitleDetailAndLabelPairOnBothSurfaces() {
        let names = Set(AppColorContrastAudit.timelineRowPairs.map(\.name))
        XCTAssertEqual(names.count, AppColorContrastAudit.timelineRowPairs.count, "a pair name appears once")
        let labels: [TimelineRowKind: String] = [
            .source: "chapter row label", .listeningMap: "map row label", .myMargin: "my Margin row label",
            .userResponse: "response row label", .sharedMargin: "shared Margin row label",
            .assistantResponse: "assistant row label"
        ]
        for base in ["bone", "listening background"] {
            for kind in TimelineRowKind.allCases {
                let fill = TimelineRowPalette.fill(kind: kind, isCurrent: false)
                for words in ["row title", "row detail", try! XCTUnwrap(labels[kind])] {
                    // A kind that shares a fill with another (the assistant and the shared Margin) shares its title and
                    // detail pairs, and names its own label.
                    XCTAssertTrue(names.contains("\(words) on \(fill.token) at \(fill.alpha) over \(base)"), "\(words) \(kind) \(base)")
                }
            }
            for kind in TimelineRowKind.allCases {
                // A current row of any kind keeps its kind's label, now on the soft green.
                XCTAssertTrue(names.contains("\(labels[kind]!) on softGreen at 1.0 over \(base)"), "current \(kind) \(base)")
            }
            for words in ["row title", "row detail", "current row label"] {
                XCTAssertTrue(names.contains("\(words) on softGreen at 1.0 over \(base)"), "\(words) current \(base)")
            }
        }
    }

    func testNoRowFindingIsKnownAnyMore() {
        XCTAssertTrue(AppColorContrastAudit.knownFailures.filter { $0.fixedBy == "#3734" }.isEmpty,
                      "#3734 is fixed: the row findings are not known failures")
        XCTAssertEqual(AppColorContrastAudit.measurements(for: AppColorContrastAudit.timelineRowPairs).filter(\.fails).map(\.description), [])
    }

    func testRowDetailAndTheMyMarginLabelReachFourAndAHalfOnPanelInLightMode() throws {
        func light(_ name: String) throws -> Double {
            let pair = try XCTUnwrap(AppColorContrastAudit.timelineRowPairs.first { $0.name == name }, name)
            return try XCTUnwrap(AppColorContrastAudit.measurements(for: [pair]).first { $0.appearance == "light" }).ratio
        }
        // The Design's numbers: today's worst row detail was 3.97:1.
        XCTAssertEqual(try light("row detail on panel at 1.0 over bone"), 5.39, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(try light("my Margin row label on panel at 1.0 over bone"), 4.5)
        XCTAssertGreaterThanOrEqual(try light("current row label on softGreen at 1.0 over bone"), 4.5)
    }

    func testTheCurrentRowsOutlineIsMeasuredOnBoneAndOnThePlate() throws {
        for name in ["current row stroke on bone", "current row stroke on listening background"] {
            let pair = try XCTUnwrap(AppColorContrastAudit.timelineRowPairs.first { $0.name == name }, name)
            XCTAssertEqual(pair.minimumRatio, 3)
            let ratios = AppColorContrastAudit.measurements(for: [pair]).map(\.ratio)
            XCTAssertEqual(ratios.count, 2, name)
            for ratio in ratios { XCTAssertGreaterThanOrEqual(ratio, 3, name) }
        }
    }

    func testThePanePairsUseTheDarkValuesInBothAppearances() throws {
        let pair = try XCTUnwrap(AppColorContrastAudit.timelineRowPairs.first {
            $0.name == "row detail on panel at 1.0 over listening background"
        })
        XCTAssertEqual(pair.foreground.light, pair.foreground.dark)
        XCTAssertEqual(pair.background.light, pair.background.dark)
        XCTAssertEqual(pair.foreground.dark, AppSemanticColorRGB.secondaryText.dark)
    }

    func testNoPanePairFails() {
        let pane = AppColorContrastAudit.timelineRowPairs.filter { $0.name.hasSuffix("over listening background") }
        XCTAssertFalse(pane.isEmpty)
        XCTAssertEqual(AppColorContrastAudit.measurements(for: pane).filter(\.fails).map(\.description), [])
    }
}
