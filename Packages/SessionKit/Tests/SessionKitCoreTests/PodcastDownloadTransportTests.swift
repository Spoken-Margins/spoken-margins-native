import Foundation
import XCTest
@testable import SessionKit

/// The rules that decide where a podcast download is fetched from and how a restarted app recognises its own
/// background tasks. Both were only reachable through the app-hosted download coordinator before.
final class PodcastDownloadTransportTests: XCTestCase {
    private func secure(_ string: String) -> String? {
        PodcastDownloadTransportURLPolicy.secureURL(for: URL(string: string)!)?.absoluteString
    }

    func testHTTPSIsLeftAlone() {
        XCTAssertEqual(secure("https://cdn.example.com/ep.mp3?token=a%20b"), "https://cdn.example.com/ep.mp3?token=a%20b")
        XCTAssertEqual(secure("https://cdn.example.com:8443/ep.mp3"), "https://cdn.example.com:8443/ep.mp3")
    }

    func testTheSchemeIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(secure("HTTPS://cdn.example.com/ep.mp3"), "HTTPS://cdn.example.com/ep.mp3")
        XCTAssertEqual(secure("HTTP://cdn.example.com/ep.mp3"), "https://cdn.example.com/ep.mp3")
        XCTAssertEqual(secure("Http://cdn.example.com/ep.mp3"), "https://cdn.example.com/ep.mp3")
    }

    func testPlainHTTPIsUpgradedAndKeepsPathQueryAndFragment() {
        XCTAssertEqual(
            secure("http://cdn.example.com/a/b%20c.mp3?x=1&y=two#t=30"),
            "https://cdn.example.com/a/b%20c.mp3?x=1&y=two#t=30"
        )
    }

    func testPort80IsDroppedButOtherPortsStay() {
        XCTAssertEqual(secure("http://cdn.example.com:80/ep.mp3"), "https://cdn.example.com/ep.mp3")
        XCTAssertEqual(secure("http://cdn.example.com:8080/ep.mp3"), "https://cdn.example.com:8080/ep.mp3")
        XCTAssertEqual(secure("http://cdn.example.com:443/ep.mp3"), "https://cdn.example.com:443/ep.mp3")
    }

    func testCredentialsInTheURLAreKept() {
        XCTAssertEqual(secure("http://user:pw@cdn.example.com/ep.mp3"), "https://user:pw@cdn.example.com/ep.mp3")
    }

    func testOtherSchemesAndRelativeLinksHaveNoTransport() {
        XCTAssertNil(secure("ftp://cdn.example.com/ep.mp3"))
        XCTAssertNil(secure("file:///var/mobile/ep.mp3"))
        XCTAssertNil(secure("//cdn.example.com/ep.mp3"))
        XCTAssertNil(secure("ep.mp3"))
        XCTAssertNil(secure("httpx://cdn.example.com/ep.mp3"))
    }

    func testTheBBCMediaSelectorGetsAnHTTPSRedirectChain() {
        XCTAssertEqual(
            secure("http://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download/proto/http/vpid/p0abc.mp3"),
            "https://open.live.bbc.co.uk/mediaselector/6/redir/version/2.0/mediaset/audio-nondrm-download/proto/https/vpid/p0abc.mp3"
        )
        XCTAssertEqual(
            secure("http://BBC.CO.UK/mediaselector/x/proto/http/y")?.lowercased(),
            "https://bbc.co.uk/mediaselector/x/proto/https/y"
        )
    }

    func testOnlyTheBBCMediaSelectorProtocolSegmentIsRewritten() {
        // A lookalike host, a non-selector path and a missing protocol segment are all left as plain scheme upgrades.
        XCTAssertEqual(secure("http://notbbc.co.uk/mediaselector/x/proto/http/y"), "https://notbbc.co.uk/mediaselector/x/proto/http/y")
        XCTAssertEqual(secure("http://bbc.co.uk.example.com/mediaselector/x/proto/http/y"), "https://bbc.co.uk.example.com/mediaselector/x/proto/http/y")
        XCTAssertEqual(secure("http://www.bbc.co.uk/programmes/proto/http/y"), "https://www.bbc.co.uk/programmes/proto/http/y")
        XCTAssertEqual(secure("http://www.bbc.co.uk/mediaselector/x/y"), "https://www.bbc.co.uk/mediaselector/x/y")
    }

    // MARK: Attempts

    func testAnAttemptRoundTripsThroughTheTaskDescription() {
        let attempt = PodcastDownloadAttempt(
            itemId: "episode-1", generation: "gen-A", reservationId: "res-9", userInitiated: true)
        XCTAssertEqual(PodcastDownloadAttempt.decode(attempt.taskDescription), attempt)
    }

    /// Background download tasks outlive the app process, so a task started by the shipped build is
    /// recognised by this one only if the stored text keeps these exact keys.
    func testATaskDescriptionWrittenByAnEarlierBuildStillDecodes() {
        let stored = #"{"itemId":"episode-1","generation":"gen-A","reservationId":"res-9","userInitiated":false}"#
        XCTAssertEqual(
            PodcastDownloadAttempt.decode(stored),
            PodcastDownloadAttempt(itemId: "episode-1", generation: "gen-A", reservationId: "res-9", userInitiated: false)
        )
    }

    func testTheTaskDescriptionKeepsTheKeysAnEarlierBuildReads() throws {
        let attempt = PodcastDownloadAttempt(
            itemId: "episode-1", generation: "gen-A", reservationId: "res-9", userInitiated: true)
        let object = try JSONSerialization.jsonObject(with: Data(attempt.taskDescription.utf8)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["itemId", "generation", "reservationId", "userInitiated"])
        XCTAssertEqual(object?["userInitiated"] as? Bool, true)
    }

    func testUnreadableTaskDescriptionsAreNotAttempts() {
        XCTAssertNil(PodcastDownloadAttempt.decode(nil))
        XCTAssertNil(PodcastDownloadAttempt.decode(""))
        XCTAssertNil(PodcastDownloadAttempt.decode("not json"))
        XCTAssertNil(PodcastDownloadAttempt.decode(#"{"itemId":"episode-1"}"#))
        XCTAssertNil(PodcastDownloadAttempt.decode(#"{"itemId":1,"generation":"g","reservationId":"r","userInitiated":true}"#))
    }

    // MARK: Failure text

    func testRefusalTextNamesTheStatusAndPageTextIsNamedAsNotAudio() {
        XCTAssertEqual(
            PodcastDownloadFailure.hostRefused(statusCode: 403).localizedDescription,
            "The episode's host refused the download (HTTP 403)."
        )
        XCTAssertEqual(
            PodcastDownloadFailure.notAudio.localizedDescription,
            "The server sent a web page or text instead of the episode's audio."
        )
    }
}
