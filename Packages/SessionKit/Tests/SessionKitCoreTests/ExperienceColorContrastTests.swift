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
