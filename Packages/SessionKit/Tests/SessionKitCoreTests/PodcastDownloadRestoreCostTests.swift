import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// What `PodcastDownloadCoordinator.restoreRecords` costs on the main thread at launch (#4221, #2507). It runs inside
/// the coordinator's synchronous `init`, so no download callback or `register` can see an empty table; moving it
/// off the main thread would open that window. It stays on main only while the read it makes is cheap, and this test
/// is what says so: 1,000 download rows, a real SQLite file, the read the coordinator makes.
final class PodcastDownloadRestoreCostTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
    }

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let elapsed = try ContinuousClock().measure(body)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    func testRestoringAThousandDownloadRecordsStaysUnderTheMainThreadBar() throws {
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        let store = try fixture.openStore(meter: StoreReadMeter())
        let seeded = try store.loadPodcastDownloads().count // the fixture's own rows are on the table too
        let now = Date()
        for index in 0..<1_000 {
            try store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(index)", itemId: "item-\(index)",
                remoteURL: "https://feeds.example.com/show-\(index % 40)/episode-\(index).mp3",
                localRelativePath: "PodcastDownloads/episode-\(index).mp3",
                state: index % 5 == 0 ? .downloading : .availableOffline,
                bytesWritten: Int64(index) * 1_000, expectedBytes: 60_000_000,
                lastPlayedAt: now, updatedAt: now.addingTimeInterval(Double(index))))
        }

        var runs: [Double] = []
        var loaded: [PodcastDownloadRecord] = []
        for _ in 0..<7 { runs.append(try milliseconds { loaded = try store.loadPodcastDownloads() }) }
        let median = runs.sorted()[runs.count / 2]
        print("DOWNLOAD-RESTORE-COST loadPodcastDownloads on 1000 rows: median \(median) ms, worst \(runs.max() ?? 0) ms")

        XCTAssertEqual(loaded.count, seeded + 1_000)
        XCTAssertTrue(loaded.contains { $0.id == "download-999" } && loaded.contains { $0.id == "download-0" })
        // The bar is 50 ms (#4221). The check fails at twice that, on the median of 7, because the figure moved between
        // 14 and 23 ms across runs on one quiet machine and a busy runner must not read as a regression.
        XCTAssertLessThan(median, 100, "restoreRecords reads this on the main thread in the coordinator's init; over the bar it needs its own design (restore as a task that register and the delegate callbacks wait for)")
    }
}
