import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Hosts the production labels of the small controls from #151 and measures the size SwiftUI gives each. The
/// hit area of a plain button is its label's frame plus content shape, so a label that measures under 44 pt in
/// either direction is a control the listener can miss. The drawn sizes (a 40 pt play circle, a 38 pt chip) are
/// unchanged; the labels reserve the extra room around them.
@MainActor
final class TapTargetSizeTests: XCTestCase {
    private static let textSizes: [(name: String, size: DynamicTypeSize)] = [
        ("default text", .large),
        ("largest accessibility text", .accessibility5),
    ]

    private func measure<V: View>(_ view: V, textSize: DynamicTypeSize) -> CGSize {
        UIHostingController(rootView: view.environment(\.dynamicTypeSize, textSize))
            .sizeThatFits(in: CGSize(width: 400, height: 800))
    }

    private func assertTapTarget(_ size: CGSize, _ name: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(size.width, TapTarget.minimum, "\(name) (\(text)) is \(size.width) pt wide", file: file, line: line)
        XCTAssertGreaterThanOrEqual(size.height, TapTarget.minimum, "\(name) (\(text)) is \(size.height) pt tall", file: file, line: line)
    }

    func testDismissAndClearIconsHaveAFortyFourPointHitArea() {
        for text in Self.textSizes {
            for symbol in ["xmark", "xmark.circle.fill"] {
                assertTapTarget(measure(TapTargetIcon(systemName: symbol), textSize: text.size), symbol, text.name)
            }
        }
    }

    func testFilterChipsHaveAFortyFourPointHitArea() {
        for text in Self.textSizes {
            let short = measure(ExperienceFilterChip(isActive: false) { Text("All") }, textSize: text.size)
            assertTapTarget(short, "A short filter chip", text.name)
            let labelled = measure(
                ExperienceFilterChip(isActive: true) { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") },
                textSize: text.size
            )
            assertTapTarget(labelled, "A Filter chip with an icon", text.name)
        }
    }

    func testCatalogSubjectChipsHaveAFortyFourPointHitArea() {
        for text in Self.textSizes {
            for isSelected in [false, true] {
                let chip = measure(CatalogSubjectChipLabel(title: "Top", isSelected: isSelected), textSize: text.size)
                assertTapTarget(chip, "A subject chip (selected: \(isSelected))", text.name)
            }
        }
    }

    func testLibraryRowPlayButtonHasAFortyFourPointHitAreaWhileKeepingItsCircle() {
        for text in Self.textSizes {
            for preparing in [false, true] {
                let label = measure(LibraryRowPlayLabel(isReadyOffline: !preparing, isPreparing: preparing), textSize: text.size)
                assertTapTarget(label, "The Library play button (preparing: \(preparing))", text.name)
            }
        }
    }

    func testMarginsSearchFieldIsAtLeastFortyFourPointsTall() {
        for text in Self.textSizes {
            let field = measure(MarginsSearchField(text: .constant("")), textSize: text.size)
            XCTAssertGreaterThanOrEqual(field.height, TapTarget.minimum, "The Margins search field (\(text.name)) is \(field.height) pt tall")
        }
    }

    /// The mini player's own buttons are 44, 46 and 44 pt wide; the near-miss fix is the gap between them. This pins
    /// the layout constant only: the spacing on screen is checked in the PR's before/after screenshots.
    func testMiniPlayerButtonsAreAtLeastTwelvePointsApart() {
        XCTAssertGreaterThanOrEqual(MiniPlayerBar.controlSpacing, 12)
    }
}
