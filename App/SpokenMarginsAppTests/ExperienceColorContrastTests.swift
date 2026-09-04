import XCTest
@testable import SpokenMarginsApp

final class ExperienceColorContrastTests: XCTestCase {
    func testSemanticTextBackgroundPairsMeetWCAGAAInLightAndDarkAppearances() {
        XCTAssertEqual(
            AppColorContrastAudit.failures(),
            [],
            "Every registered foreground/background pair must meet its deterministic contrast floor"
        )
    }
}
