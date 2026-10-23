import Foundation
import XCTest
@testable import SessionKit

/// The Debug-only host override behind the offline check (#1842, #2058): a Debug build launched with
/// `-SMServerHost offline.invalid` sends every server feature to a host that never resolves, and
/// without the argument, or in a Release build, everything stays on the real server.
final class ProductServerTests: XCTestCase {
    private let real = "spokenmargins.proximitytoprogress.com"

    func testWithoutTheArgumentEveryServerFeatureUsesTheRealHost() {
        XCTAssertEqual(ProductServer.host, real)
        XCTAssertEqual(BridgeManifestPolicy.production.configURL.absoluteString, "https://\(real)/api/v1/config.json")
        XCTAssertEqual(BridgeManifestPolicy.production.manifestURL.absoluteString, "https://\(real)/bridge/v1/manifest.json")
        XCTAssertEqual(BridgeManifestPolicy.production.trustedHost, real)
        XCTAssertEqual(SourceCatalogPolicy.production.manifestURL.absoluteString, "https://\(real)/onboarding/catalog/v1/manifest.json")
        XCTAssertEqual(SourceCatalogPolicy.production.trustedHost, real)
        XCTAssertEqual(CommunityMapFetcher.mapsURL.absoluteString, "https://\(real)/api/v1/maps/")
        XCTAssertEqual(CommunityMapUploader.transcriptsURL.absoluteString, "https://\(real)/api/v1/maps/transcripts")
    }

    func testADebugBuildTakesTheHostFromTheLaunchArgument() {
        let arguments = ["SpokenMarginsApp", "-SMServerHost", "Offline.Invalid"]
        XCTAssertEqual(ProductServer.resolveHost(arguments: arguments, debugBuild: true), "offline.invalid")
    }

    func testAReleaseBuildIgnoresTheLaunchArgument() {
        let arguments = ["SpokenMarginsApp", "-SMServerHost", "offline.invalid"]
        XCTAssertEqual(ProductServer.resolveHost(arguments: arguments, debugBuild: false), real)
    }

    func testTheTestTargetIsADebugBuild() {
        XCTAssertTrue(ProductServer.isDebugBuild)
    }

    func testAMissingOrMalformedValueKeepsTheRealHost() {
        let rows: [[String]] = [
            ["app"],
            ["app", "-SMServerHost"],
            ["app", "-SMServerHost", ""],
            ["app", "-SMServerHost", "https://offline.invalid"],
            ["app", "-SMServerHost", "offline.invalid:443"],
            ["app", "-SMServerHost", "offline.invalid/api"],
            ["app", "-SMServerHost", "user@offline.invalid"],
            ["app", "-SMServerHost", "offline..invalid"],
            ["app", "-SMServerHost", ".invalid"],
            ["app", "-SMServerHost", "-offline.invalid"],
            ["app", "-SMServerHost", "offline invalid"],
            ["app", "-SMServerHost", "öffline.invalid"],
            ["app", "-SMServerHost", String(repeating: "a", count: 64) + ".invalid"],
            ["app", "-smserverhost", "offline.invalid"],
        ]
        for arguments in rows {
            XCTAssertEqual(ProductServer.resolveHost(arguments: arguments, debugBuild: true), real, "\(arguments)")
        }
    }

    func testTheLastValueWinsAndAnIPAddressIsAccepted() {
        let arguments = ["app", "-SMServerHost", "first.invalid", "-SMServerHost", "127.0.0.1"]
        XCTAssertEqual(ProductServer.resolveHost(arguments: arguments, debugBuild: true), "127.0.0.1")
    }

    /// A real link someone sent still opens as a share link under the override, so the offline check sees
    /// the download fail instead of the link being passed on to Safari and the real server.
    func testARealShareLinkIsStillRecognisedWhenTheHostIsOverridden() {
        let id = String(repeating: "a", count: ShareLinkURL.idLength)
        let hosts = [real, "offline.invalid"]
        XCTAssertTrue(ShareLinkURL.isOnShareHost(URL(string: "https://\(real)/l/\(id)")!, hosts: hosts))
        XCTAssertTrue(ShareLinkURL.isOnShareHost(URL(string: "https://offline.invalid/l/\(id)")!, hosts: hosts))
        XCTAssertFalse(ShareLinkURL.isOnShareHost(URL(string: "https://example.com/l/\(id)")!, hosts: hosts))
        XCTAssertFalse(ShareLinkURL.isOnShareHost(URL(string: "http://\(real)/l/\(id)")!, hosts: hosts))
    }

    /// The override has to fail the way a down server does, as a network error, not as an untrusted URL
    /// the app refuses to send: the pinned-host check must accept the overridden host.
    func testAnOverriddenHostPassesThePinnedHostCheck() {
        let host = "offline.invalid"
        let policy = BridgeManifestPolicy(
            configURL: ProductServer.url(host: host, path: "/api/v1/config.json"),
            manifestURL: ProductServer.url(host: host, path: "/bridge/v1/manifest.json"),
            trustedHost: host
        )
        XCTAssertEqual(policy.configURL.absoluteString, "https://offline.invalid/api/v1/config.json")
        XCTAssertTrue(policy.isTrusted(policy.configURL))
        XCTAssertTrue(policy.isTrusted(policy.manifestURL))
        XCTAssertFalse(policy.isTrusted(URL(string: "https://\(real)/api/v1/config.json")!))
    }
}
