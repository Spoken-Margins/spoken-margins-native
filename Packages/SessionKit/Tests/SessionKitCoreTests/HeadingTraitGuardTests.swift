import XCTest
import SessionKitTestInputs

/// #3729: the Headings rotor jumps between sections only where a title carries the heading trait. #1916 marked the
/// screen titles; these guards cover the section titles it left: the item screen's sections, the Live session's headlines,
/// the Margins tab's item groups and the share extension's title.
///
/// They read the app's `.swift` files as text (#4306): the screens cannot be built on Linux. Each scans the specific
/// title's code with comments removed, so a trait that only a comment mentions does not count. `SourceTextRules` takes the
/// text so the self-tests can show it fails on a mutated copy.
final class HeadingTraitGuardTests: XCTestCase {
    enum SourceTextRules {
        static let trait = ".accessibilityAddTraits(.isHeader)"

        /// Every `sectionHeading` function's `Text(title)` line carries the heading trait. Returns how many it found.
        static func sectionHeadings(_ text: String) -> (found: Int, problems: [String]) {
            let code = SwiftSourceScan.code(text)
            var found = 0
            var problems: [String] = []
            var rest = Substring(code)
            while let marker = rest.range(of: "func sectionHeading(") {
                found += 1
                let from = String(rest[marker.lowerBound...])
                if let body = SwiftSourceScan.body(after: "func sectionHeading(", in: from) {
                    let title = body.components(separatedBy: "\n").first { $0.contains("Text(title)") }
                    if title?.contains(trait) != true { problems.append("sectionHeading #\(found) has no heading trait on its Text(title)") }
                } else {
                    problems.append("sectionHeading #\(found) has no body")
                }
                rest = rest[marker.upperBound...]
            }
            return (found, problems)
        }

        /// Every `.font(.headline)` line carries `.isHeader`, except the one whose raw line says it is a field label.
        /// The marker is read from the raw line, because comments are removed from the code.
        static func headlines(_ text: String) -> (found: Int, problems: [String]) {
            let raw = text.components(separatedBy: "\n")
            let code = SwiftSourceScan.code(text).components(separatedBy: "\n")
            let headlines = code.indices.filter { code[$0].contains(".font(.headline)") }
            let problems = headlines.filter { !raw[$0].contains("a field label") && !code[$0].contains(".isHeader") }
                .map { "line \($0 + 1) is a headline without the heading trait" }
            return (headlines.count, problems)
        }

        /// The Margins tab group title: its `margins.openItem.` identifier line has `.isButton` and `.isHeader` just above.
        static func groupTitleProblems(_ text: String) -> [String] {
            let code = SwiftSourceScan.code(text).components(separatedBy: "\n")
            guard let identifier = code.firstIndex(where: { $0.contains("margins.openItem.") && $0.contains("accessibilityIdentifier") }) else {
                return ["the margins.openItem identifier is gone"]
            }
            let traits = code[max(0, identifier - 2)...identifier].joined(separator: "\n")
            return traits.contains(".isButton") && traits.contains(".isHeader") ? [] : ["the group title must keep .isButton and add .isHeader"]
        }

        /// The pinned card's `Text(card.headline)` statement carries the trait, within its next lines.
        static func pinnedHeadlineProblems(_ text: String) -> [String] {
            let code = SwiftSourceScan.code(text).components(separatedBy: "\n")
            guard let start = code.firstIndex(where: { $0.contains("Text(card.headline)") }) else { return ["Text(card.headline) is gone"] }
            let body = code[start..<min(start + 4, code.count)].joined(separator: "\n")
            return body.contains(trait) ? [] : ["the card headline has no heading trait"]
        }

        static func shareTitleProblems(_ text: String) -> [String] {
            SwiftSourceScan.code(text).contains("titleLabel.accessibilityTraits.insert(.header)") ? [] : ["the share title lost the header trait"]
        }
    }

    private func source(_ input: TestInputs.Input, _ name: String) throws -> String {
        try String(contentsOf: try TestInputs.directory(input).appending(path: name), encoding: .utf8)
    }

    /// The item screen's `sectionHeading` is used for Recent Margins, Listening sessions, Chapters and the Listening Map.
    func testEveryItemScreenSectionHeadingCarriesTheHeaderTraitInSourceText() throws {
        var found = 0
        for name in ["ExperienceItemDetailScreen.swift", "ExperienceReactionsScreen.swift"] {
            let result = SourceTextRules.sectionHeadings(try source(.appSources, name))
            found += result.found
            XCTAssertEqual(result.problems, [], name)
        }
        XCTAssertGreaterThanOrEqual(found, 3, "the scan must find every sectionHeading")
    }

    /// Every headline on the Live session screens is a section title, except the one marked as a field label.
    /// The screen drawn like playback (#3491) keeps three: the setup field label, "Session ended" and "End Session".
    func testEveryLiveSessionHeadlineCarriesTheHeaderTraitInSourceText() throws {
        let result = SourceTextRules.headlines(try source(.appSources, "LiveSessionView.swift"))
        XCTAssertGreaterThanOrEqual(result.found, 3, "the scan must see the headlines")
        XCTAssertEqual(result.problems, [])
    }

    /// An item's group title in the Margins tab is a button that opens the item, and also a heading.
    func testTheMarginsTabGroupTitleIsAButtonAndAHeadingInSourceText() throws {
        XCTAssertEqual(SourceTextRules.groupTitleProblems(try source(.appSources, "ExperienceMarginsScreen.swift")), [])
    }

    /// The pinned Margin card's headline is the card's title.
    func testThePinnedMarginCardHeadlineIsAHeadingInSourceText() throws {
        XCTAssertEqual(SourceTextRules.pinnedHeadlineProblems(try source(.appSources, "PinnedMarginCardView.swift")), [])
    }

    /// UIKit: the share extension's title label.
    func testTheShareExtensionTitleHasTheHeaderTraitInSourceText() throws {
        XCTAssertEqual(SourceTextRules.shareTitleProblems(try source(.appShareExtension, "Sources/SourceLinkShareViewController.swift")), [])
    }

    // MARK: the rules fail on the mutations issue #4306 names

    func testATraitLeftOnlyInACommentIsNotATraitOnTheSectionHeadings() throws {
        let text = try source(.appSources, "ExperienceItemDetailScreen.swift")
        let real = ".accessibilityAddTraits(.isHeader)\n            Text(detail)"
        XCTAssertTrue(text.contains(real), "the mutation below must find both section headings' trait")
        let mutated = text.replacingOccurrences(of: real, with: " // .accessibilityAddTraits(.isHeader)\n            Text(detail)")
        XCTAssertEqual(SourceTextRules.sectionHeadings(mutated).problems.count, 2, "both headings lost the trait, one comment each")
        XCTAssertEqual(SourceTextRules.sectionHeadings(text).problems, [])
    }

    func testTheTraitOnTheDetailLineDoesNotCountForTheTitle() {
        let text = "func sectionHeading(_ title: String, detail: String) -> some View {\n  VStack {\n    Text(title)\n    Text(detail).accessibilityAddTraits(.isHeader)\n  }\n}"
        XCTAssertEqual(SourceTextRules.sectionHeadings(text).problems.count, 1)
    }

    func testAHeadlineWithOnlyACommentedTraitIsCaughtAndTheFieldLabelIsExempt() {
        let bare = "Text(\"a\").font(.headline) // .isHeader\n"
        XCTAssertEqual(SourceTextRules.headlines(bare).problems.count, 1)
        let label = "Text(\"a\").font(.headline) // a field label, not a section title\n"
        XCTAssertEqual(SourceTextRules.headlines(label).problems, [])
        let ok = "Text(\"a\").font(.headline).accessibilityAddTraits(.isHeader)\n"
        XCTAssertEqual(SourceTextRules.headlines(ok).problems, [])
    }

    func testTheCardAndShareTitleChecksIgnoreComments() {
        XCTAssertNotEqual(SourceTextRules.pinnedHeadlineProblems("Text(card.headline)\n// .accessibilityAddTraits(.isHeader)\n"), [])
        XCTAssertNotEqual(SourceTextRules.shareTitleProblems("// titleLabel.accessibilityTraits.insert(.header)\n"), [])
        XCTAssertNotEqual(SourceTextRules.groupTitleProblems("// .isButton .isHeader\n.accessibilityIdentifier(\"margins.openItem.x\")"), [])
    }
}
