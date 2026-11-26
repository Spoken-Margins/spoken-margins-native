import XCTest
@testable import SessionKit

/// #4778: compact Timeline rows say each thing once. A chapter's type is its icon and one "Chapter:" to VoiceOver, its
/// place is the corner, a folded chapter's hidden count is on the fold control and never in the row, and a link folds
/// its host into its kind line.
final class TimelineRowLinesTests: XCTestCase {
    private let title = "The Quest for Sane Regulations"

    // MARK: lines and icons per role

    func testEachRoleGetsItsIconsKindLineAndHeaderTrait() {
        let table: [(String, TimelineRowRole, Bool, String?, String?, String?, Bool)] = [
            // name, role, compact, leading icon, kind line, kind icon, header
            ("chapter", .chapter, true, "list.bullet", nil, nil, true),
            ("beginning", .beginning, true, "backward.end", nil, nil, false),
            ("link with host", .sourceElement(kind: .link, linkHost: "x.com"), true, nil, "Link · x.com", "link", false),
            ("link without host", .sourceElement(kind: .link, linkHost: nil), true, nil, "Link", "link", false),
            ("link with empty host", .sourceElement(kind: .link, linkHost: ""), true, nil, "Link", "link", false),
            ("picture", .sourceElement(kind: .picture, linkHost: nil), true, nil, "Picture", "photo", false),
            ("embed", .sourceElement(kind: .embed, linkHost: nil), true, nil, "Embed", "play.rectangle", false),
            ("table", .sourceElement(kind: .table, linkHost: nil), true, nil, "Table", "tablecells", false),
            ("full", .full, false, nil, nil, nil, false),
        ]
        for (name, role, compact, leading, kindLine, kindIcon, header) in table {
            let lines = TimelineRowLines(role: role)
            XCTAssertEqual(lines.isCompact, compact, name)
            XCTAssertEqual(lines.leadingSystemImage, leading, name)
            XCTAssertEqual(lines.kindLine, kindLine, name)
            XCTAssertEqual(lines.kindSystemImage, kindIcon, name)
            XCTAssertEqual(lines.isHeader, header, name)
        }
    }

    func testKindNamesAreTheOnesTheSheetAndRowShare() {
        XCTAssertEqual(TimelineRowLines.kindName(.link), "Link")
        XCTAssertEqual(TimelineRowLines.kindName(.picture), "Picture")
        XCTAssertEqual(TimelineRowLines.kindName(.embed), "Embed")
        XCTAssertEqual(TimelineRowLines.kindName(.table), "Table")
    }

    // MARK: VoiceOver labels: role crossed with plain, current, folded with the playhead inside

    func testChapterLabelsMatchTheDesignTable() {
        XCTAssertEqual(spoken(.chapter), "Chapter: The Quest for Sane Regulations, 48 percent.")
        XCTAssertEqual(spoken(.chapter, current: "Current chapter, 51%"),
                       "Current chapter, 51%. The Quest for Sane Regulations. Starts at 48 percent.")
        XCTAssertEqual(spoken(.chapter, containsCurrent: true),
                       "Chapter: The Quest for Sane Regulations, 48 percent. Playing in this chapter.")
        XCTAssertEqual(spoken(.chapter, current: "Current chapter, 51%", containsCurrent: true),
                       "Current chapter, 51%. The Quest for Sane Regulations. Starts at 48 percent.",
                       "a current row doesn't also say the playhead is folded inside it")
        XCTAssertEqual(TimelineRowLines.spokenLabel(role: .chapter, title: "  ", spokenPosition: "48 percent",
                                                    currentSpoken: nil, containsCurrent: false),
                       "Chapter: Untitled chapter, 48 percent.")
    }

    func testEveryChapterLabelSaysItsTypeAndPlaceOnceAndNeverTheHiddenCount() {
        let places = ["48 percent", "about 65 percent", "1 hour, 7 minutes, 30 seconds"]
        for place in places {
            for current in [nil, "Current chapter, 51%"] as [String?] {
                for containsCurrent in [false, true] {
                    let label = TimelineRowLines.spokenLabel(role: .chapter, title: title, spokenPosition: place,
                                                             currentSpoken: current, containsCurrent: containsCurrent) ?? ""
                    let name = "\(place) current=\(current ?? "nil") inside=\(containsCurrent)"
                    XCTAssertEqual(occurrences(of: "Chapter", in: label), current == nil ? 1 : 0, name)
                    XCTAssertLessThanOrEqual(occurrences(of: "Current chapter", in: label), 1, name)
                    XCTAssertEqual(occurrences(of: place, in: label), 1, name)
                    XCTAssertEqual(occurrences(of: title, in: label), 1, name)
                    XCTAssertFalse(label.contains("rows hidden") || label.contains("row hidden"), name)
                    XCTAssertFalse(label.contains("Chapter ·"), name)
                }
            }
        }
    }

    func testBeginningLabelReadsItsPlaceThenTheOverview() {
        XCTAssertEqual(spoken(.beginning, title: "Beginning", place: "0 percent"), "Beginning, 0 percent.")
        XCTAssertEqual(TimelineRowLines.spokenLabel(role: .beginning, title: "Beginning", spokenPosition: "0 percent",
                                                    currentSpoken: nil, containsCurrent: false, detail: "A short overview."),
                       "Beginning, 0 percent. A short overview.")
        XCTAssertEqual(spoken(.beginning, title: "Beginning", place: "0 percent", current: "Current chapter, 0%"),
                       "Current chapter, 0%. Beginning, 0 percent.")
    }

    func testSourceElementLabelsNameTheirKindAndHost() {
        let link = TimelineRowRole.sourceElement(kind: .link, linkHost: "x.com")
        XCTAssertEqual(spoken(link, title: "Senator Chris Van Hollen", place: "50 percent"),
                       "Link to x.com: Senator Chris Van Hollen, 50 percent.")
        XCTAssertEqual(spoken(.sourceElement(kind: .link, linkHost: nil), title: "Senator", place: "50 percent"),
                       "Link: Senator, 50 percent.")
        XCTAssertEqual(spoken(.sourceElement(kind: .picture, linkHost: nil), title: "A map", place: "50 percent"),
                       "Picture: A map, 50 percent.")
        XCTAssertEqual(spoken(.sourceElement(kind: .embed, linkHost: nil), title: "YouTube video", place: "50 percent"),
                       "Embed: YouTube video, 50 percent.")
        XCTAssertEqual(spoken(.sourceElement(kind: .table, linkHost: nil), title: "Year, Cost", place: "50 percent"),
                       "Table: Year, Cost, 50 percent.")
        XCTAssertFalse(spoken(link, title: "x", place: "50 percent", containsCurrent: true)?.contains("Playing") ?? true,
                       "only chapters say the playhead is folded inside them")
    }

    func testFullRowsKeepTheirOwnLabel() {
        XCTAssertNil(spoken(.full))
    }

    // MARK: the fold control

    func testFoldControlLabelValueAndInputLabels() {
        XCTAssertEqual(TimelineRowLines.foldLabel(isFolded: true), "Expand")
        XCTAssertEqual(TimelineRowLines.foldLabel(isFolded: false), "Collapse")
        let folded = TimelineChapterFolding.HiddenSummary(hiddenCount: 3, hasNew: false, containsCurrent: false)
        let foldedNew = TimelineChapterFolding.HiddenSummary(hiddenCount: 3, hasNew: true, containsCurrent: true)
        XCTAssertEqual(TimelineRowLines.foldValue(summary: folded), "3 rows hidden")
        XCTAssertEqual(TimelineRowLines.foldValue(summary: foldedNew), "3 rows hidden, new inside")
        XCTAssertEqual(TimelineRowLines.foldValue(summary: nil), "Expanded")
        XCTAssertEqual(TimelineRowLines.foldInputLabels(isFolded: true, title: title),
                       ["Expand", "Expand chapter", "Expand \(title)"])
        XCTAssertEqual(TimelineRowLines.foldInputLabels(isFolded: false, title: ""),
                       ["Collapse", "Collapse chapter", "Collapse Untitled chapter"])
        XCTAssertEqual(TimelineRowLines.rowFoldActionName(isFolded: true), "Expand chapter")
        XCTAssertEqual(TimelineRowLines.rowFoldActionName(isFolded: false), "Collapse chapter")
    }

    func testDisplayTitleOnlyFillsAnEmptyChapter() {
        XCTAssertEqual(TimelineRowLines.displayTitle(role: .chapter, title: ""), "Untitled chapter")
        XCTAssertEqual(TimelineRowLines.displayTitle(role: .chapter, title: title), title)
        XCTAssertEqual(TimelineRowLines.displayTitle(role: .sourceElement(kind: .link, linkHost: nil), title: ""), "")
    }

    // MARK: helpers

    private func spoken(_ role: TimelineRowRole, title: String? = nil, place: String = "48 percent",
                        current: String? = nil, containsCurrent: Bool = false) -> String? {
        TimelineRowLines.spokenLabel(role: role, title: title ?? self.title, spokenPosition: place,
                                     currentSpoken: current, containsCurrent: containsCurrent)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
