import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Moved from the app test target (#318): the contrast audit is Foundation only, so it runs on the host.
final class ExperienceColorContrastTests: XCTestCase {
    /// Not every registered pair: `AppColorContrastAudit.knownFailures` lists the pairs exempt until their own issue
    /// fixes them (the faint default border and input fills on purpose, #1922; the Timeline and Watch
    /// findings, #3734, #3731). The guard tests prove each entry still fails and that no new failure is unlisted.
    func testEveryPairNotListedAsAKnownFailureMeetsItsContrastFloorInLightAndDark() {
        XCTAssertEqual(
            AppColorContrastAudit.failures(),
            [],
            "Every registered pair that is not a known failure must meet its deterministic contrast floor"
        )
        for known in AppColorContrastAudit.knownFailures {
            XCTAssertFalse(known.fixedBy.isEmpty, "\(known.pair) [\(known.appearance)] is exempt with no issue to fix it")
        }
    }

    func testIncreasedContrastEdgesReachThreeToOneInLightAndDark() {
        XCTAssertEqual(
            AppColorContrastAudit.failures(for: AppColorContrastAudit.increasedContrastEdgePairs),
            [],
            "Under Increase Contrast every border must reach 3:1 against its surface"
        )
    }

    func testTheDefaultBorderIsUnchangedAndStillFaint() {
        // The default look with Increase Contrast off must not move (#1922): the border stays a hairline.
        let ratio = AppColorContrastAudit.contrastRatio(
            foreground: AppSemanticColorRGB.border.light, background: AppSemanticColorRGB.panel.light)
        XCTAssertLessThan(ratio, 2)
        XCTAssertEqual(AppSemanticColorRGB.border.light, AppColorRGB(red: 0.84, green: 0.87, blue: 0.81))
        XCTAssertEqual(AppSemanticColorRGB.border.dark, AppColorRGB(red: 0.28, green: 0.34, blue: 0.30))
    }

    func testContrastRatioMatchesTheWCAGDefinitionAtItsEnds() {
        let black = AppColorRGB(red: 0, green: 0, blue: 0)
        let white = AppColorRGB(red: 1, green: 1, blue: 1)
        XCTAssertEqual(AppColorContrastAudit.contrastRatio(foreground: black, background: white), 21, accuracy: 0.0001)
        XCTAssertEqual(AppColorContrastAudit.contrastRatio(foreground: white, background: black), 21, accuracy: 0.0001,
                       "the ratio does not depend on which colour is the foreground")
        XCTAssertEqual(AppColorContrastAudit.contrastRatio(foreground: white, background: white), 1, accuracy: 0.0001)
    }

    func testAuditRegistersPairsAndEveryRegisteredPairIsNamedOnce() {
        let names = AppColorContrastAudit.textBackgroundPairs.map(\.name)
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testAuditNamesTheFailingAppearance() {
        // A pair that passes in light but fails in dark must be reported for dark only, so the audit cannot be
        // satisfied by checking a single appearance.
        let pair = AppColorContrastAudit.Pair(
            name: "grey on grey",
            foreground: AppDynamicRGB(light: .init(red: 0, green: 0, blue: 0), dark: .init(red: 0.5, green: 0.5, blue: 0.5)),
            background: AppDynamicRGB(light: .init(red: 1, green: 1, blue: 1), dark: .init(red: 0.5, green: 0.5, blue: 0.5)),
            minimumRatio: 4.5)
        XCTAssertEqual(AppColorContrastAudit.failures(for: [pair]), ["grey on grey [dark] 1.00:1"])
    }
}

/// #1921: the audit must cover every colour the app draws with, and say what it knows is failing.
final class AppColorContrastCoverageTests: XCTestCase {
    /// Read into a `let` first: a skip thrown inside an `XCTAssert` expression would be recorded as a failure.
    private func tokenSource() throws -> String {
        let url = TestInputs.packageRoot.appending(path: "Sources/SessionKit/ExperienceColorContrast.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func appColorsSource() throws -> String {
        try TestInputs.text(.appSources, "Gate1RootView.swift")
    }

    private func block(_ text: String, startingAt header: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: header), "\(header) not found").upperBound
        let rest = text[start...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private func names(in text: String, pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testEveryTokenIsInTheTokenListAndInAtLeastOnePair() throws {
        let file = try tokenSource()
        let body = try block(file, startingAt: "public enum AppSemanticColorRGB {")
        let declared = try names(in: body, pattern: #"public static let (\w+) = "#).filter { $0 != "all" }
        let listed = AppSemanticColorRGB.all.map(\.name)
        XCTAssertEqual(Set(declared), Set(listed), "AppSemanticColorRGB.all must name every token")
        XCTAssertEqual(Set(listed).count, listed.count)

        // A token is covered when some pair uses its exact values as foreground or background. `ochre` is the fill and
        // tint colour only, never a text or icon colour (`ochreText` is, and is audited), so no text sits on its own value
        // alone; the next test keeps it out of foregrounds (#1920).
        let used = AppColorContrastAudit.allPairs.flatMap { [$0.foreground, $0.background] }
        let fillsOnly: Set<String> = ["ochre"]
        for token in AppSemanticColorRGB.all where !fillsOnly.contains(token.name) {
            XCTAssertTrue(used.contains(token.color), "\(token.name) has no pair in the contrast audit")
        }
    }

    func testTheAppBuildsEveryColourFromTheSharedTokens() throws {
        let app = try appColorsSource()
        let body = try block(app, startingAt: "enum AppColors {")
        let colours = try names(in: body, pattern: #"static let (\w+) = "#)
        XCTAssertGreaterThan(colours.count, 20)
        for line in body.split(separator: "\n") where line.contains("static let") {
            XCTAssertTrue(
                line.contains("AppSemanticColorRGB."),
                "AppColors must take its values from AppSemanticColorRGB so the audit sees them: \(line)"
            )
        }
    }

    /// #4045: iOS draws a swipe button's words in white, and a normal token turns light in dark mode (white on it was
    /// 1.75:1 to 2.23:1). Every tint inside a `swipeActions` block is one of the fixed `swipe…` tokens, whose white
    /// pairs the audit measures. Whitespace is collapsed first, so a block or tint split over lines is still seen.
    static func swipeTintsThatAreNotSwipeTokens(in text: String) -> [String] {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var found: [String] = []
        var searchRange = collapsed.startIndex..<collapsed.endIndex
        while let match = collapsed.range(of: #"\.swipeActions\b"#, options: .regularExpression, range: searchRange) {
            // Skip the call's own arguments if it has any, then take the braces that follow as the block.
            var index = match.upperBound
            if collapsed[index...].drop(while: { $0 == " " }).first == "(" {
                index = collapsed[index...].firstIndex(of: "(") ?? index
                var depth = 0
                repeat {
                    if collapsed[index] == "(" { depth += 1 } else if collapsed[index] == ")" { depth -= 1 }
                    index = collapsed.index(after: index)
                } while index < collapsed.endIndex && depth > 0
            }
            guard let open = collapsed[index...].firstIndex(of: "{") else { break }
            var braces = 1
            var cursor = collapsed.index(after: open)
            while cursor < collapsed.endIndex, braces > 0 {
                if collapsed[cursor] == "{" { braces += 1 } else if collapsed[cursor] == "}" { braces -= 1 }
                cursor = collapsed.index(after: cursor)
            }
            let block = String(collapsed[open..<cursor])
            let regex = try? NSRegularExpression(pattern: #"\.tint\(\s*([^)]*)\)"#)
            for tint in regex?.matches(in: block, range: NSRange(block.startIndex..., in: block)) ?? [] {
                guard let range = Range(tint.range(at: 1), in: block) else { continue }
                let argument = block[range].trimmingCharacters(in: .whitespaces)
                if !argument.hasPrefix("AppColors.swipe") { found.append(argument) }
            }
            searchRange = cursor..<collapsed.endIndex
        }
        return found
    }

    func testTheSwipeTintGuardSeesEveryWayToTintASwipeButton() {
        let check = Self.swipeTintsThatAreNotSwipeTokens(in:)
        XCTAssertEqual(check(".swipeActions(edge: .leading) { Button(action: a) { Label(\"A\", systemImage: \"x\") }.tint(AppColors.evergreen) }"), ["AppColors.evergreen"])
        XCTAssertEqual(check(".swipeActions(edge: .leading) { Button(action: a) { Label(\"A\", systemImage: \"x\") }.tint(AppColors.swipeEvergreen) }"), [])
        XCTAssertEqual(check(".swipeActions {\n Button(\"R\") { r() }\n .tint(\n AppColors.ochreText\n )\n }"), ["AppColors.ochreText"], "a tint split over lines")
        XCTAssertEqual(check(".swipeActions(edge: .trailing, allowsFullSwipe: false) { Button(\"R\") { r() }.tint(.blue) }"), [".blue"], "a system colour")
        XCTAssertEqual(check(".swipeActions { if x { Button(\"A\") {}.tint(AppColors.swipePlum) } else { Button(\"B\") {}.tint(AppColors.plum) } }"), ["AppColors.plum"], "inside an if")
        XCTAssertEqual(check(".swipeActions(edge: .leading) { Button(\"A\") {}.tint(AppColors.swipeSlate) } .swipeActions(edge: .trailing) { Button(\"B\") {}.tint(AppColors.secondaryText) }"), ["AppColors.secondaryText"], "the second block after a clean one")
        XCTAssertEqual(check(".tint(AppColors.evergreen) Text(\"x\")"), [], "a tint outside a swipe block is not this guard's business")
        XCTAssertEqual(check(".swipeActions { Button(\"A\") {} } .tint(AppColors.evergreen)"), [], "a tint after the block")
        XCTAssertEqual(check(".swipeActions(edge: .trailing) { Button(\"Delete\", role: .destructive) {} }"), [], "no tint at all")
        XCTAssertEqual(check(""), [])
    }

    func testEverySwipeButtonIsTintedWithAFixedSwipeToken() throws {
        let directory = try TestInputs.directory(.appSources)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var found: [String] = []
        var blocks = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            blocks += text.components(separatedBy: ".swipeActions").count - 1
            found += Self.swipeTintsThatAreNotSwipeTokens(in: text).map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertGreaterThanOrEqual(blocks, 6, "the guard must see the app's swipe blocks")
        XCTAssertEqual(found, [], "a swipe button's white words need a fixed AppColors.swipe… token (#4045)")
    }

    func testTheSwipeTokensAreTheLightModeTintsInBothAppearances() {
        let pairs: [(AppDynamicRGB, AppDynamicRGB)] = [
            (AppSemanticColorRGB.swipeEvergreen, AppSemanticColorRGB.evergreen),
            (AppSemanticColorRGB.swipeOchre, AppSemanticColorRGB.ochreText),
            (AppSemanticColorRGB.swipePlum, AppSemanticColorRGB.plum),
            (AppSemanticColorRGB.swipeSlate, AppSemanticColorRGB.secondaryText)
        ]
        for (swipe, source) in pairs {
            XCTAssertEqual(swipe.light, source.light, "the same hue as light mode today")
            XCTAssertEqual(swipe.dark, swipe.light, "fixed in both appearances")
        }
    }

    /// #1920: ochre in light mode is 2.8:1 on bone and the system orange about 2:1 on white. Text and icons use
    /// `ochreText` and `warningText`, which the audit measures; `ochre` stays a fill. The playback card is dark in both
    /// appearances, where ochre and the system orange are 7:1 and more, so its files are the only ones allowed.
    func testNoTextOrIconIsDrawnInOchreOrTheSystemOrange() throws {
        let allowedBecauseTheyAreAlwaysDark: Set<String> = [
            "PlaybackScreen.swift", "PlaybackFeedbackTagView.swift", "PlaybackMarginTranscriptionStatusView.swift",
            "LiveActivityTourPreview.swift"
        ]
        let directory = try TestInputs.directory(.appSources)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var found: [String] = []
        for file in files where !allowedBecauseTheyAreAlwaysDark.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            found += Self.ochreOrOrangeMarks(in: text).map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(found, [], "use AppColors.ochreText or AppColors.warningText for text and icons")
    }

    /// What the guard calls a mark drawn in ochre or the system orange, in Swift source: as a foreground or tint however
    /// the colour is modified (`.opacity` and `.overlay` included, #3711), or as an arm of a ternary or switch that
    /// returns a colour. Whitespace is collapsed first, so a modifier split over lines is still seen. A fill (a
    /// `.background` or a surface's `tint:` argument) is allowed, and so is an `.opacity` tint on a switch arm: those
    /// are the Timeline row fills.
    static func ochreOrOrangeMarks(in text: String) -> [String] {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var found: [String] = []
        let mark = #"AppColors\.ochre(?!Text)\b|(?<!\w)\.orange\b|Color\.orange\b"#
        if foregroundOrTintArguments(in: collapsed).contains(where: { $0.range(of: mark, options: .regularExpression) != nil }) {
            found.append("foreground or tint")
        }
        let arms: [String] = [
            #"[?:]\s*AppColors\.ochre(?!Text)\b(?!\.(?:opacity|overlay))"#,
            #"[?:]\s*(Color)?\.orange\b"#
        ]
        if arms.contains(where: { collapsed.range(of: $0, options: .regularExpression) != nil }) {
            found.append("ternary or switch arm")
        }
        return found
    }

    /// The text inside each `foregroundStyle(`, `foregroundColor(` or `tint(` call, closed by matching parentheses, so a
    /// nested call such as `Color(white: 1) : AppColors.ochre.opacity(0.9)` does not end the search early.
    private static func foregroundOrTintArguments(in text: String) -> [String] {
        var arguments: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: #"(?<![A-Za-z0-9_])(foregroundStyle|foregroundColor|tint)\("#, options: .regularExpression, range: searchRange) {
            var depth = 1
            var index = match.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            arguments.append(String(text[match.upperBound..<index]))
            searchRange = match.upperBound..<text.endIndex
        }
        return arguments
    }

    func testTheOchreGuardSeesEveryWayToDrawAMarkInIt() {
        let drawn = [
            "Text(\"x\").foregroundStyle(AppColors.ochre)",
            "Text(\"x\").foregroundStyle(AppColors.ochre.opacity(0.9))",
            "Image(systemName: \"star\").foregroundColor(AppColors.ochre.opacity(0.9))",
            "Button(\"x\") {}.tint(AppColors.ochre.opacity(0.5))",
            "Text(\"x\").foregroundStyle(AppColors.ochre.overlay { Color.white })",
            "Text(\"x\").foregroundStyle(isOn ? AppColors.ochre.opacity(0.9) : .primary)",
            "Text(\"x\")\n    .foregroundStyle(\n        AppColors.ochre\n            .opacity(0.9)\n    )",
            "Text(\"x\").foregroundStyle(.orange)",
            "Text(\"x\").foregroundStyle(Color.orange.opacity(0.8))",
            "Text(\"x\").foregroundStyle(isOn ? Color(white: 1) : AppColors.ochre.opacity(0.9))",
            "Text(\"x\").foregroundStyle(Color(white: 0.2).mix(with: AppColors.ochre.opacity(0.5)))"
        ]
        for source in drawn {
            XCTAssertFalse(Self.ochreOrOrangeMarks(in: source).isEmpty, "the guard missed: \(source)")
        }
        let fills = [
            "Text(\"x\").foregroundStyle(AppColors.ochreText)",
            "Circle().background(AppColors.ochre.opacity(0.12), in: Circle())",
            "ExperienceSurface(tint: AppColors.ochre.opacity(0.16)) { Text(\"x\") }",
            "case .userResponse: AppColors.ochre.opacity(0.08)",
            "Text(\"x\").foregroundStyle(.primary).background(AppColors.ochre.opacity(0.1))",
            "Text(\"x\").foregroundStyle(AppColors.warningText)",
            "Text(\"x\").foregroundStyle(Color(white: 1)).background(AppColors.ochre.opacity(0.1))"
        ]
        for source in fills {
            XCTAssertEqual(Self.ochreOrOrangeMarks(in: source), [], "the guard flagged a fill: \(source)")
        }
    }

    /// #3732: the follow-a-source card put the dark `watchControl` tint behind light-mode text (secondary text 2.5:1,
    /// the system blue and red buttons 1.9:1 and 1.7:1). The `watch*` colours are made for the always-dark playback
    /// surface, so only the `Playback*` files may use them.
    /// The running live session is drawn on the playback screen's dark surface, by the owner's choice (#3491).
    private static let liveSessionDarkSurface: Set<String> = [
        "LiveSessionDock.swift", "LiveSessionMarginsPane.swift", "LiveSessionSessionPane.swift", "LiveSessionView.swift"
    ]

    func testWatchColoursStayOnTheAlwaysDarkPlaybackSurface() throws {
        let directory = try TestInputs.directory(.appSources)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        var found: [String] = []
        for file in files {
            let name = file.lastPathComponent
            if name.hasPrefix("Playback") || Self.liveSessionDarkSurface.contains(name) { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: #"AppColors\.watch\w+"#, options: .regularExpression) != nil {
                found.append(name)
            }
        }
        XCTAssertEqual(found, [], "use AppColors.panel, softGreen or bone outside the always-dark playback surface")
    }

    /// #3737: the share extension's status line was `.secondaryLabel` (3.3:1) on `.secondarySystemBackground` in light
    /// mode, and its icon the system green (2.0:1). The extension doesn't link SessionKit, so it carries a copy of the
    /// app's `green` token; this keeps the copy equal to the token and measures it against the card.
    func testShareExtensionStatusAndIconAreReadableOnItsCard() throws {
        let source = try TestInputs.text(.appShareExtension, "Sources/SourceLinkShareViewController.swift")
        XCTAssertTrue(source.contains("statusLabel.textColor = .label"), "the status line uses .label")
        XCTAssertFalse(source.contains("secondaryLabel"), "no secondary text on the extension's card")
        XCTAssertFalse(source.contains("systemGreen"), "the icon uses the app's green, not the system green")

        let pattern = #"iconView\.tintColor = UIColor \{ traits in\s*traits\.userInterfaceStyle == \.dark\s*\?\s*UIColor\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: 1\)\s*:\s*UIColor\(red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), alpha: 1\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let match = try XCTUnwrap(regex.firstMatch(in: source, range: range), "the icon's dynamic colour was not found")
        let numbers = (1...6).map { index -> Double in
            Double(String(source[Range(match.range(at: index), in: source)!]))!
        }
        let dark = AppColorRGB(red: numbers[0], green: numbers[1], blue: numbers[2])
        let light = AppColorRGB(red: numbers[3], green: numbers[4], blue: numbers[5])
        XCTAssertEqual(light, AppSemanticColorRGB.green.light)
        XCTAssertEqual(dark, AppSemanticColorRGB.green.dark)

        // iOS's secondarySystemBackground: #F2F2F7 in light, #1C1C1E in dark. Label is black / white on it.
        let card = AppSystemColorRGB.secondarySystemBackground
        let ratios = [
            AppColorContrastAudit.contrastRatio(foreground: light, background: card.light),
            AppColorContrastAudit.contrastRatio(foreground: dark, background: card.dark)
        ]
        for ratio in ratios { XCTAssertGreaterThanOrEqual(ratio, 3, "the icon needs 3:1 on the card") }
        let systemGreenLight = AppColorRGB(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
        XCTAssertLessThan(
            AppColorContrastAudit.contrastRatio(foreground: systemGreenLight, background: card.light), 3,
            "the old system green fails here, so this check can fail")
    }

    func testKnownFailuresAreListedAndStillFail() {
        for line in AppColorContrastAudit.knownFailureReport() { print(line) }
        XCTAssertEqual(AppColorContrastAudit.staleKnownFailures(), [], "delete the entries that now pass")
    }

    func testBothKindsOfPairAreAudited() {
        XCTAssertTrue(AppColorContrastAudit.textBackgroundPairs.allSatisfy { $0.minimumRatio == 4.5 })
        XCTAssertTrue(AppColorContrastAudit.nonTextPairs.allSatisfy { $0.minimumRatio == 3 })
        let names = AppColorContrastAudit.allPairs.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "pair names are unique")
    }
}
