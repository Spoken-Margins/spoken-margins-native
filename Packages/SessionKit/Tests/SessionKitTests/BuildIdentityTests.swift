import XCTest
@testable import SessionKit

final class BuildIdentityTests: XCTestCase {
    func testWithoutCommitKeepsTheShippedFormat() {
        XCTAssertEqual(BuildIdentity.describe(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "29"]),
                       "0.1 (29)")
    }

    func testPhoneBuildNamesItsCommit() {
        let info = ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "29",
                    BuildIdentity.commitInfoKey: "9d422f623d0ab775f657ad9352a23fca51280e8d"]
        XCTAssertEqual(BuildIdentity.describe(info: info), "0.1 (29) · 9d422f6")
    }

    func testEmptyOrUnexpandedCommitIsIgnored() {
        for commit in ["", "  ", "$(SM_BUILD_COMMIT)"] {
            let info = ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "30", BuildIdentity.commitInfoKey: commit]
            XCTAssertEqual(BuildIdentity.describe(info: info), "0.1 (30)")
        }
    }

    func testMissingKeysSayUnknown() {
        XCTAssertEqual(BuildIdentity.describe(info: [:]), "unknown (unknown)")
    }
}
