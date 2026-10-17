import XCTest
@testable import SessionKit

/// Moved from the app test target (#318): the contrast audit is Foundation only, so it runs on the host.
final class ExperienceColorContrastTests: XCTestCase {
    func testSemanticTextBackgroundPairsMeetWCAGAAInLightAndDarkAppearances() {
        XCTAssertEqual(
            AppColorContrastAudit.failures(),
            [],
            "Every registered foreground/background pair must meet its deterministic contrast floor"
        )
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
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "project.yml").path) {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private func source(_ relativePath: String) throws -> String {
        let url = Self.repositoryRoot.appending(path: relativePath)
        return try XCTUnwrap(
            try? String(contentsOf: url, encoding: .utf8),
            "\(relativePath) is missing, so this coverage test cannot check anything"
        )
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
        let file = try source("Packages/SessionKit/Sources/SessionKit/ExperienceColorContrast.swift")
        let body = try block(file, startingAt: "public enum AppSemanticColorRGB {")
        let declared = try names(in: body, pattern: #"public static let (\w+) = "#).filter { $0 != "all" }
        let listed = AppSemanticColorRGB.all.map(\.name)
        XCTAssertEqual(Set(declared), Set(listed), "AppSemanticColorRGB.all must name every token")
        XCTAssertEqual(Set(listed).count, listed.count)

        // A token is covered when some pair uses its exact values as foreground or background.
        let used = AppColorContrastAudit.allPairs.flatMap { [$0.foreground, $0.background] }
        for token in AppSemanticColorRGB.all {
            XCTAssertTrue(used.contains(token.color), "\(token.name) has no pair in the contrast audit")
        }
    }

    func testTheAppBuildsEveryColourFromTheSharedTokens() throws {
        let app = try source("App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift")
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
