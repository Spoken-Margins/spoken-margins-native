import Foundation
@testable import SessionKit
import XCTest

/// The Timeline rows' fill, stroke and label colours come from `TimelineRowPalette`, and the contrast audit generates
/// its row pairs from the same palette (#3734).
final class TimelineRowPaletteTests: XCTestCase {
    func testThePaletteHoldsTheValuesTheViewDrewBeforeTheAuditSawThem() {
        func fill(_ kind: TimelineRowKind, _ current: Bool = false) -> TimelineRowPalette.Fill {
            TimelineRowPalette.fill(kind: kind, isCurrent: current)
        }
        XCTAssertEqual(fill(.source), .init(token: "panel", color: AppSemanticColorRGB.panel, alpha: 1))
        XCTAssertEqual(fill(.listeningMap), .init(token: "evergreen", color: AppSemanticColorRGB.evergreen, alpha: 0.07))
        XCTAssertEqual(fill(.myMargin), .init(token: "coral", color: AppSemanticColorRGB.coral, alpha: 0.08))
        XCTAssertEqual(fill(.userResponse), .init(token: "ochre", color: AppSemanticColorRGB.ochre, alpha: 0.08))
        XCTAssertEqual(fill(.sharedMargin), .init(token: "plum", color: AppSemanticColorRGB.plum, alpha: 0.07))
        XCTAssertEqual(fill(.assistantResponse), fill(.sharedMargin))
        for kind in TimelineRowKind.allCases {
            XCTAssertEqual(fill(kind, true), .init(token: "evergreen", color: AppSemanticColorRGB.evergreen, alpha: 0.12), "\(kind)")
        }
        XCTAssertEqual(TimelineRowPalette.currentLabelColor, AppSemanticColorRGB.evergreen)
    }

    func testStrokesAreTheKindsColourAndOnlyTheAssistantsIsDashed() {
        for kind in TimelineRowKind.allCases {
            for current in [false, true] {
                let stroke = TimelineRowPalette.stroke(kind: kind, isCurrent: current)
                XCTAssertEqual(stroke.color, TimelineRowPalette.labelColor(kind: kind), "\(kind)")
                XCTAssertEqual(stroke.width, 1)
                XCTAssertEqual(stroke.dashed, kind == .assistantResponse)
                XCTAssertEqual(stroke.alpha, kind == .assistantResponse ? 0.55 : 0.24)
            }
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
            for words in ["row title", "row detail", "current row label"] {
                XCTAssertTrue(names.contains("\(words) on evergreen at 0.12 over \(base)"), "\(words) current \(base)")
            }
        }
    }

    func testTheOldRowPairsKeepTheirNamesSoTheirKnownFailuresStillMatch() {
        let names = Set(AppColorContrastAudit.timelineRowPairs.map(\.name))
        let rowFailures = AppColorContrastAudit.knownFailures.filter { $0.fixedBy == "#3734" }
        XCTAssertEqual(rowFailures.count, 6)
        for failure in rowFailures { XCTAssertTrue(names.contains(failure.pair), failure.pair) }
    }

    func testThePanePairsUseTheDarkValuesInBothAppearances() throws {
        let pair = try XCTUnwrap(AppColorContrastAudit.timelineRowPairs.first {
            $0.name == "row detail on coral at 0.08 over listening background"
        })
        XCTAssertEqual(pair.foreground.light, pair.foreground.dark)
        XCTAssertEqual(pair.background.light, pair.background.dark)
        XCTAssertEqual(pair.foreground.dark, AppSemanticColorRGB.secondaryText.dark)
    }

    func testNoPanePairFailsToday() {
        let pane = AppColorContrastAudit.timelineRowPairs.filter { $0.name.hasSuffix("over listening background") }
        XCTAssertFalse(pane.isEmpty)
        XCTAssertEqual(AppColorContrastAudit.measurements(for: pane).filter(\.fails).map(\.description), [])
    }
}
