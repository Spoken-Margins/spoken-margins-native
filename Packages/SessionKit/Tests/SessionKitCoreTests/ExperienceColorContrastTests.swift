import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Moved from the app test target (#318): the contrast audit is Foundation only, so it runs on the host.
final class ExperienceColorContrastTests: XCTestCase {
    func testSemanticTextBackgroundPairsMeetWCAGAAInLightAndDarkAppearances() {
        XCTAssertEqual(
            AppColorContrastAudit.failures(),
            [],
            "Every registered foreground/background pair must meet its deterministic contrast floor"
        )
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
        // Whitespace is collapsed first, so a modifier split over lines is still seen. A mark drawn in ochre or the
        // system orange: as a foreground or tint, or as an arm of a ternary or switch that returns a colour. A fill
        // (`.opacity` tints, a shape's `.overlay`) is allowed.
        let banned: [(String, String)] = [
            (#"(foregroundStyle|foregroundColor|tint)\(\s*(AppColors\.ochre(?!Text)\b(?!\.(?:opacity|overlay))|\.orange\b|Color\.orange\b)"#, "foreground or tint"),
            (#"[?:]\s*AppColors\.ochre(?!Text)\b(?!\.(?:opacity|overlay))"#, "ternary or switch arm"),
            (#"[?:]\s*(Color)?\.orange\b"#, "ternary or switch arm")
        ]
        var found: [String] = []
        for file in files where !allowedBecauseTheyAreAlwaysDark.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            for (pattern, what) in banned where collapsed.range(of: pattern, options: .regularExpression) != nil {
                found.append("\(file.lastPathComponent): \(what)")
            }
        }
        XCTAssertEqual(found, [], "use AppColors.ochreText or AppColors.warningText for text and icons")
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
        let card = AppDynamicRGB(
            light: .init(red: 242 / 255, green: 242 / 255, blue: 247 / 255),
            dark: .init(red: 28 / 255, green: 28 / 255, blue: 30 / 255))
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
