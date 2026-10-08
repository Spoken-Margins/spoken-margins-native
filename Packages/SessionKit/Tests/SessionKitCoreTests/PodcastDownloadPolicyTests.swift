import Foundation
import XCTest
@testable import SessionKit

/// When a podcast episode downloads by itself, and which downloaded episodes go first when the cache is full.
///
/// `testPodcastDownloadPolicyNeverAutomaticallyDownloadsOnCellular` (Mac-only target) leaves out two of the
/// eight cases, including `.other` without the listener asking: the connection class the download coordinator
/// starts with, and the one an unclassified link such as a tethered phone reports. The eviction test it sits next
/// to gives every downloaded episode a `lastPlayedAt`, so the fallback for an episode never played, and the order
/// of two equally old ones, are never used.
final class PodcastDownloadPolicyTests: XCTestCase {
    func testEveryTransportAndWhoStartedTheDownloadHasItsOwnAnswer() {
        let table: [(PodcastNetworkTransport, userInitiated: Bool, PodcastDownloadAction)] = [
            (.wifi, false, .download),
            (.wifi, true, .download),
            (.cellular, false, .streamOnly),
            (.cellular, true, .download),
            (.other, false, .waitForWiFi),
            (.other, true, .download),
            (.unavailable, false, .waitForWiFi),
            (.unavailable, true, .waitForWiFi),
        ]
        for (transport, userInitiated, expected) in table {
            XCTAssertEqual(
                PodcastDownloadPolicy.action(for: transport, userInitiated: userInitiated), expected,
                "\(transport), \(userInitiated ? "the listener asked" : "automatic")"
            )
        }
    }

    // MARK: Eviction order

    private func downloaded(
        _ itemId: String, bytes: Int64 = 3_000, lastPlayedAt: Date? = nil, updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PodcastDownloadRecord {
        PodcastDownloadRecord(
            id: "download-\(itemId)", itemId: itemId, remoteURL: "https://example.com/\(itemId).mp3",
            state: .availableOffline, bytesWritten: bytes, lastPlayedAt: lastPlayedAt, updatedAt: updatedAt
        )
    }

    func testAnEpisodeThatWasNeverPlayedIsEvictedBeforeOnesThatWere() {
        let records = [
            downloaded("played-long-ago", lastPlayedAt: Date(timeIntervalSince1970: 100)),
            downloaded("never-played"),
            downloaded("played-recently", lastPlayedAt: Date(timeIntervalSince1970: 300)),
        ]

        let evictions = PodcastCacheEvictionPlanner.recordsToEvict(from: records, limitBytes: 6_000, protectedItemIds: [])

        XCTAssertEqual(evictions.map(\.itemId), ["never-played"])
    }

    func testTwoEpisodesPlayedAtTheSameTimeGoOldestUpdateFirst() {
        // Listed newest-updated first, so the answer cannot come from the order of the array.
        let records = [
            downloaded("updated-later", updatedAt: Date(timeIntervalSince1970: 2_000)),
            downloaded("updated-earlier", updatedAt: Date(timeIntervalSince1970: 1_000)),
        ]
        XCTAssertEqual(
            PodcastCacheEvictionPlanner.recordsToEvict(from: records, limitBytes: 3_000, protectedItemIds: []).map(\.itemId),
            ["updated-earlier"], "never played, so equally old"
        )

        let played = Date(timeIntervalSince1970: 500)
        let samePlay = [
            downloaded("updated-later", lastPlayedAt: played, updatedAt: Date(timeIntervalSince1970: 2_000)),
            downloaded("updated-earlier", lastPlayedAt: played, updatedAt: Date(timeIntervalSince1970: 1_000)),
        ]
        XCTAssertEqual(
            PodcastCacheEvictionPlanner.recordsToEvict(from: samePlay, limitBytes: 3_000, protectedItemIds: []).map(\.itemId),
            ["updated-earlier"], "played at the same moment"
        )
    }

    func testAnEpisodeThatIsInUseIsKeptEvenWhenItWasNeverPlayed() {
        let records = [
            downloaded("playing-now"),
            downloaded("played", lastPlayedAt: Date(timeIntervalSince1970: 100)),
        ]

        let evictions = PodcastCacheEvictionPlanner.recordsToEvict(from: records, limitBytes: 3_000, protectedItemIds: ["playing-now"])

        XCTAssertEqual(evictions.map(\.itemId), ["played"])
    }
}
