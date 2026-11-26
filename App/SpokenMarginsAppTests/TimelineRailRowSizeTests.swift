import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4778: compact Timeline rows. A folded chapter with a one-line title was at least 92 pt plus 12 pt below; it is now a
/// header of about 50 pt, with no text made smaller. At accessibility sizes the row grows to hold every part: nothing clips.
@MainActor
final class TimelineRailRowSizeTests: XCTestCase {
    /// A 390 pt phone, less 36 pt of screen padding and the 52 pt the fold control and its gap take at least.
    private let width: CGFloat = 302

    func testAFoldedOneLineChapterIsACompactHeader() {
        let row = chapterRow(title: "Introduction", corner: "12%", hidden: 12)
        XCTAssertLessThanOrEqual(height(row, .large), 60, "6 pt below included")
    }

    func testAFoldedChapterWithALongerTitleStaysCompact() {
        let row = chapterRow(title: "The Quest for Sane Regulations", corner: "about 65%", hidden: 12)
        // The title has about 140 pt beside the rail, icon and corner, so it may take two or three lines. Even at three it
        // stays under today's floor of 104 pt (a 92 pt card and 12 pt below), which is the claim this test pins.
        XCTAssertLessThanOrEqual(height(row, .large), 96)
    }

    func testALinkRowFoldsItsHostIntoItsKindLine() {
        let element = SourceElement(id: "l", kind: .link, start: 0, label: "Senator Chris Van Hollen", url: "https://x.com/s")
        let entry = TimelineRailEntry(id: "source.element.l", position: 50, rank: 0, provenance: .source,
                                      title: element.label, detail: "", action: .sourceElement(element))
        let row = TimelineRailRow(entry: entry, isCurrent: false, isFirst: false, isLast: false, action: {})
        XCTAssertLessThanOrEqual(height(row, .large), 76)
    }

    func testAtAnAccessibilitySizeTheChapterRowHoldsItsTitleAndPlace() {
        let title = "The Quest for Sane Regulations"
        let corner = "about 65%"
        let row = chapterRow(title: title, corner: corner, hidden: 12)
        // Measured wider than the card's text column, so these heights are a floor for what the row must hold.
        let textWidth = width - 24
        let titleHeight = height(Text(title).font(.headline), .accessibility3, width: textWidth)
        let cornerHeight = height(Text(corner).font(.caption.monospacedDigit()), .accessibility3, width: textWidth)
        XCTAssertGreaterThanOrEqual(height(row, .accessibility3), titleHeight + cornerHeight + 4 + 20 + 6,
                                    "the title and the place stack, and neither is clipped")
    }

    // MARK: helpers

    private func chapterRow(title: String, corner: String, hidden: Int) -> TimelineRailRow {
        let chapter = Chapter(id: "c", title: title, startChar: 0, endChar: 10, percent: 50)
        let entry = TimelineRailEntry(id: "source.chapter.c", position: 50, rank: 0, provenance: .source, title: title,
                                      detail: "", action: .chapter(chapter),
                                      positionLabel: .init(corner: corner, spoken: corner))
        return TimelineRailRow(entry: entry, isCurrent: false, isFirst: false, isLast: false,
                               hidden: .init(hiddenCount: hidden, hasNew: false, containsCurrent: false), action: {})
    }

    private func height(_ view: some View, _ size: DynamicTypeSize, width: CGFloat? = nil) -> CGFloat {
        let root = view
            .frame(width: width ?? self.width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, size)
        return UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width ?? self.width, height: 4_000)).height
    }
}
