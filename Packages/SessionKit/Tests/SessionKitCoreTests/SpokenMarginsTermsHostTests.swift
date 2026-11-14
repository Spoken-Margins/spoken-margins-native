import Foundation
import XCTest
@testable import SessionKit

/// The Terms acceptance rules, moved out of the app-hosted tests (#318). The text in the app bundle is still
/// checked in the app's `SpokenMarginsTermsStorageTests`.
final class SpokenMarginsTermsHostTests: XCTestCase {
    private func freshDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "spoken-margins-terms-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testAcceptanceIsVersionedAndExpiresWhenTheVersionChanges() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))
        XCTAssertNil(SpokenMarginsTerms.acceptedVersion(in: defaults))
        XCTAssertNil(SpokenMarginsTerms.acceptedAt(in: defaults))

        let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)
        SpokenMarginsTerms.recordAcceptance(at: acceptedAt, in: defaults)

        XCTAssertTrue(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))
        XCTAssertEqual(SpokenMarginsTerms.acceptedVersion(in: defaults), SpokenMarginsTerms.currentVersion)
        XCTAssertEqual(SpokenMarginsTerms.acceptedAt(in: defaults), acceptedAt)

        for older in ["older-version", "", "1.0.0", " 1.0", "0.9"] {
            defaults.set(older, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults), "'\(older)' is not the current version")
        }
    }

    func testClearingAcceptanceRemovesTheVersionAndTheDate() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        SpokenMarginsTerms.recordAcceptance(in: defaults)
        XCTAssertTrue(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))

        SpokenMarginsTerms.clearAcceptance(in: defaults)

        XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))
        XCTAssertNil(defaults.object(forKey: SpokenMarginsTerms.acceptanceVersionKey))
        XCTAssertNil(defaults.object(forKey: SpokenMarginsTerms.acceptanceDateKey))
    }

    func testAcceptanceOnlyTouchesItsOwnKeys() throws {
        let (defaults, cleanup) = try freshDefaults()
        defer { cleanup() }
        defaults.set("kept", forKey: "ttsVoiceSelection")
        SpokenMarginsTerms.recordAcceptance(in: defaults)
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), "kept")
    }

    /// Earlier builds saved acceptance under these keys. Renaming one would ask every listener to accept again.
    func testTheStoredKeysAndLinksAreThoseEarlierBuildsUsed() {
        XCTAssertEqual(SpokenMarginsTerms.acceptanceVersionKey, "spokenMarginsTermsAcceptedVersion")
        XCTAssertEqual(SpokenMarginsTerms.acceptanceDateKey, "spokenMarginsTermsAcceptedAt")
        XCTAssertEqual(SpokenMarginsTerms.publicURL.scheme, "https")
        XCTAssertEqual(SpokenMarginsTerms.appleStandardEULAURL.host, "www.apple.com")
    }

    func testErrorsSayWhatToDo() {
        XCTAssertEqual(SpokenMarginsTermsError.acceptanceRequired.errorDescription,
                       "Accept the current Spoken Margins Terms of Use before enabling an on-device voice.")
        XCTAssertEqual(SpokenMarginsTermsError.bundledTermsUnavailable.errorDescription,
                       "The bundled Spoken Margins Terms of Use are unavailable. The on-device voice remains disabled.")
    }
}
