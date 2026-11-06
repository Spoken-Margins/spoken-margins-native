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
        // Temporary: these two audio-named files get their `ochreText` edit in a follow-up PR, because the test lane's
        // audio plan needs a BlackHole loopback that the hosted Mac lacks (#3467). The follow-up deletes this set.
        let allowedUntilTheAudioFollowUp: Set<String> = [
            "ExperienceAudioPreparationQueueScreen.swift", "PlaybackTimelineListView.swift"
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
        for file in files
        where !allowedBecauseTheyAreAlwaysDark.contains(file.lastPathComponent)
            && !allowedUntilTheAudioFollowUp.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            for (pattern, what) in banned where collapsed.range(of: pattern, options: .regularExpression) != nil {
                found.append("\(file.lastPathComponent): \(what)")
            }
        }
        XCTAssertEqual(found, [], "use AppColors.ochreText or AppColors.warningText for text and icons")
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
