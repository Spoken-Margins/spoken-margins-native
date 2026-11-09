import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #3752: starting a podcast moves the `activePlayback` protection by reading only the ledger rows that can change.
/// Every table row checks the result against what the old whole-ledger loop did on a twin database.
final class ActivePlaybackProtectionTests: XCTestCase {
    private func asset(
        _ id: String, item: String? = nil, _ category: OfflineAssetCategory = .podcast, path: String? = nil,
        protections: Set<OfflineProtectionReason> = []
    ) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: id, itemId: item, category: category, relativePath: path ?? "PodcastAudio/\(id).mp3", byteCount: 10,
            isReproducible: true, protections: protections
        )
    }

    private func makeStore(_ rows: [OwnedOfflineAsset], meter: StoreReadMeter? = nil) throws -> (SQLiteSessionStore, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("active-protection-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path, readMeter: meter)
        for row in rows { try store.saveOwnedOfflineAsset(row) }
        return (store, path)
    }

    /// The loop `PodcastDownloadCoordinator.configureActiveItem` ran before #3752, kept here as the reference.
    private func wholeLedgerLoop(_ store: SQLiteSessionStore, itemId: String?, activePath: String?) throws {
        for asset in try store.loadOwnedOfflineAssets() where asset.category == .podcast {
            let isActive = itemId != nil && (asset.itemId == itemId || (activePath != nil && asset.relativePath == activePath))
            let wasActive = asset.protections.contains(.activePlayback)
            guard isActive != wasActive else { continue }
            _ = try store.updateOwnedOfflineAsset(id: asset.id) { current in
                if isActive { current.protections.insert(.activePlayback) } else { current.protections.remove(.activePlayback) }
            }
        }
    }

    private var ledger: [OwnedOfflineAsset] {
        [
            asset("new-1", item: "new"),
            asset("new-2", item: "new", protections: [.activePlayback]),
            asset("old", item: "old", protections: [.activePlayback]),
            asset("old-also-committing", item: "old", protections: [.activePlayback, .activeCommit]),
            asset("adopted", path: "PodcastAudio/new.mp3"),
            asset("adopted-held", path: "PodcastAudio/held.mp3", protections: [.activePlayback]),
            asset("bystander", item: "other"),
            asset("bystander-protected", item: "other", protections: [.activeCommit]),
            asset("book", item: "new", .audiobook),
            asset("book-held", item: "old", .audiobook, protections: [.activePlayback]),
            asset("prepared-same-path", .preparedAudio, path: "PodcastAudio/new.mp3"),
            asset("name-mentions-reason", item: "other", path: "PodcastAudio/active_playback.mp3"),
            asset("empty-item", item: ""),
        ]
    }

    func testEveryCaseLeavesTheLedgerAsTheOldLoopDid() throws {
        let cases: [(String, String?, String?)] = [
            ("a new item with a path alias", "new", "PodcastAudio/new.mp3"),
            ("a new item with no saved file", "new", nil),
            ("a path with no item row", "fresh", "PodcastAudio/new.mp3"),
            ("an item with no rows at all", "nowhere", nil),
            ("playback ended", nil, nil),
            ("playback ended, a stale path", nil, "PodcastAudio/new.mp3"),
            ("the item that already holds it", "old", nil),
            ("an empty item id", "", nil),
            ("an empty path", "new", ""),
        ]
        for (name, itemId, activePath) in cases {
            let (store, path) = try makeStore(ledger)
            let (twin, twinPath) = try makeStore(ledger)
            defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: twinPath) }

            ActivePlaybackProtection.move(in: store, toItem: itemId, activePath: activePath)
            try wholeLedgerLoop(twin, itemId: itemId, activePath: activePath)

            let mine = try store.loadOwnedOfflineAssets().map { [$0.id: $0.protections] }
            let reference = try twin.loadOwnedOfflineAssets().map { [$0.id: $0.protections] }
            XCTAssertEqual(mine, reference, name)
        }
    }

    func testTheProtectionEndsUpOnTheNewEpisodeAndOffTheOldOne() throws {
        let (store, path) = try makeStore(ledger)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let changed = ActivePlaybackProtection.move(in: store, toItem: "new", activePath: "PodcastAudio/new.mp3")

        let rows = Dictionary(uniqueKeysWithValues: try store.loadOwnedOfflineAssets().map { ($0.id, $0.protections) })
        XCTAssertEqual(rows["new-1"], [.activePlayback])
        XCTAssertEqual(rows["adopted"], [.activePlayback], "the row at the active path, with no item id")
        XCTAssertEqual(rows["old"], [])
        XCTAssertEqual(rows["old-also-committing"], [.activeCommit], "only activePlayback comes off")
        XCTAssertEqual(rows["adopted-held"], [])
        XCTAssertEqual(rows["book"], [], "another category is never protected")
        XCTAssertEqual(rows["book-held"], [.activePlayback], "and never unprotected")
        XCTAssertEqual(rows["prepared-same-path"], [], "a prepared-audio row at the same path is not a podcast")
        XCTAssertEqual(changed, 5, "new-1, adopted, old, old-also-committing, adopted-held")
    }

    func testAMoveReadsOnlyTheRowsThatCanChange() throws {
        let meter = StoreReadMeter()
        var rows = ledger
        for index in 0..<400 { rows.append(asset("filler-\(index)", item: "filler-\(index)")) }
        for index in 0..<200 { rows.append(asset("filler-prepared-\(index)", item: "filler-\(index)", .preparedAudio)) }
        let (store, path) = try makeStore(rows, meter: meter)
        defer { try? FileManager.default.removeItem(atPath: path) }

        meter.reset()
        ActivePlaybackProtection.move(in: store, toItem: "new", activePath: "PodcastAudio/new.mp3")
        let read = meter.totals(for: "loadOwnedOfflineAssets(category:itemId:relativePath:holding:)")

        XCTAssertGreaterThan(read.rows, 0)
        XCTAssertLessThanOrEqual(read.rows, 12, "of \(rows.count) ledger rows; the whole-ledger read decoded all of them")
    }

    func testNothingIsLeftOnTheLabelStackAndAMoveWithNothingToDoWritesNothing() throws {
        let (store, path) = try makeStore([asset("only", item: "a")])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let labels = MainThreadOperationLabels()

        XCTAssertEqual(ActivePlaybackProtection.move(in: store, toItem: "elsewhere", activePath: nil, labels: labels), 0)
        XCTAssertEqual(ActivePlaybackProtection.move(in: store, toItem: "a", activePath: nil, labels: labels), 1)
        XCTAssertEqual(ActivePlaybackProtection.move(in: store, toItem: "a", activePath: nil, labels: labels), 0, "already protected")
        XCTAssertEqual(labels.current, "")
    }
}
