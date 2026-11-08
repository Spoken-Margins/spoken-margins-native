import XCTest
import SessionKitTestInputs

/// #3729: the Headings rotor jumps between sections only where a title carries the heading trait. #1916 marked the
/// screen titles; these guards cover the section titles it left: the item screen's sections, the Live session's headlines,
/// the Margins tab's item groups and the share extension's title.
final class HeadingTraitGuardTests: XCTestCase {
    private func source(_ input: TestInputs.Input, _ name: String) throws -> [String] {
        let directory = try TestInputs.directory(input)
        let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    /// The item screen's `sectionHeading` is used for Recent Margins, Listening sessions, Chapters and the Listening Map.
    func testEveryItemScreenSectionHeadingCarriesTheHeaderTrait() throws {
        var found = 0
        for name in ["ExperienceItemDetailScreen.swift", "ExperienceReactionsScreen.swift"] {
            let lines = try source(.appSources, name)
            let starts = lines.indices.filter { lines[$0].contains("func sectionHeading(") }
            found += starts.count
            for start in starts {
                let body = lines[start..<min(start + 6, lines.count)].joined(separator: "\n")
                XCTAssertTrue(body.contains(".accessibilityAddTraits(.isHeader)"), "\(name): sectionHeading at line \(start + 1) has no heading trait")
            }
        }
        XCTAssertGreaterThanOrEqual(found, 3, "the scan must find every sectionHeading")
    }

    /// Every headline on the Live session screens is a section title, except the one marked as a field label.
    func testEveryLiveSessionHeadlineCarriesTheHeaderTrait() throws {
        let lines = try source(.appSources, "LiveSessionView.swift")
        let headlines = lines.indices.filter { lines[$0].contains(".font(.headline)") }
        XCTAssertGreaterThanOrEqual(headlines.count, 5, "the scan must see the headlines")
        for index in headlines where !lines[index].contains("a field label") {
            XCTAssertTrue(lines[index].contains(".isHeader"), "LiveSessionView.swift:\(index + 1) is a headline without the heading trait")
        }
    }

    /// An item's group title in the Margins tab is a button that opens the item, and also a heading.
    func testTheMarginsTabGroupTitleIsAButtonAndAHeading() throws {
        let lines = try source(.appSources, "ExperienceMarginsScreen.swift")
        let identifier = try XCTUnwrap(lines.firstIndex { $0.contains("margins.openItem.") && $0.contains("accessibilityIdentifier") })
        let traits = lines[max(0, identifier - 2)...identifier].joined(separator: "\n")
        XCTAssertTrue(traits.contains(".isButton") && traits.contains(".isHeader"), "the group title must keep .isButton and add .isHeader")
    }

    /// UIKit: the share extension's title label.
    func testTheShareExtensionTitleHasTheHeaderTrait() throws {
        let lines = try source(.appShareExtension, "Sources/SourceLinkShareViewController.swift")
        XCTAssertTrue(lines.contains { $0.contains("titleLabel.accessibilityTraits.insert(.header)") })
    }
}
