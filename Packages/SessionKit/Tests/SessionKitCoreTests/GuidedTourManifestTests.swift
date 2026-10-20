#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// The guided tour the website publishes (#2051): the manifest the app downloads must name the clip that sits
/// next to it, with that clip's checksum, or the app's checksum check refuses the tour on every phone.
final class GuidedTourManifestTests: XCTestCase {
    func testPublishedManifestNamesTheCommittedClipWithItsChecksum() throws {
        let manifestData = try TestInputs.data(.site, "onboarding/v1/manifest.json")
        let manifest = try JSONDecoder().decode(GuidedOnboardingManifest.self, from: manifestData)
        let fileName = try XCTUnwrap(URL(string: manifest.audioURL)?.lastPathComponent)
        XCTAssertEqual(manifest.audioURL, "https://spokenmargins.proximitytoprogress.com/onboarding/v1/\(fileName)")

        let audio = try TestInputs.data(.site, "onboarding/v1/\(fileName)")
        let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(manifest.audioChecksumSHA256, checksum)
        // The cached copy is named by contentVersion, so a new clip needs a new version.
        XCTAssertGreaterThanOrEqual(manifest.contentVersion, 2, "the iOS-voiced v1 clip must not come back")
    }
}
