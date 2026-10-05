import Foundation
import XCTest
@testable import SessionKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Standalone Watch media: what it can play, atomic installs, and position reconciliation (#789).
final class WatchStandaloneMediaTests: XCTestCase {
    private final class UnsyncedMargins: WatchUnsyncedMarginChecking {
        var revisions: Set<String> = []
        func hasUnsyncedMargins(itemId: String, sourceRevision: String) -> Bool {
            revisions.contains("\(itemId)@\(sourceRevision)")
        }
    }

    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let r1 = WatchMediaIdentity(itemId: "episode-1", sourceRevision: "r1", kind: .podcastEpisode, mediaId: "guid-1")
    private var r2: WatchMediaIdentity { WatchMediaIdentity(itemId: "episode-1", sourceRevision: "r2", kind: .podcastEpisode, mediaId: "guid-1") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchStandaloneMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var mediaFolder: URL { root.appendingPathComponent("watch-media", isDirectory: true) }

    /// A real file plus the manifest the phone would send with it.
    private func media(_ identity: WatchMediaIdentity, bytes: Int = 64_000, seed: UInt8 = 3, durationMs: Int = 1_800_000) throws -> (URL, WatchMediaTransferManifest) {
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed)) })
        let url = root.appendingPathComponent("send-\(UUID().uuidString).m4a")
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, WatchMediaTransferManifest(identity: identity, fileExtension: "m4a", byteCount: data.count, sha256: sha, durationMs: durationMs))
    }

    private func truncatedCopy(of url: URL, bytes: Int) throws -> URL {
        let copy = root.appendingPathComponent("partial-\(UUID().uuidString).m4a")
        try Data(try Data(contentsOf: url).prefix(bytes)).write(to: copy)
        return copy
    }

    // MARK: - What the Watch can play

    private let feedURL = URL(string: "https://example.com/episode-1.mp3")!

    func testOnlineWithNothingInstalledStreamsTheCurrentRevision() {
        let result = WatchMediaAvailability.playability(
            currentRevision: "r1", installs: [], remote: (r1, WatchMediaRemote(url: feedURL), 1_800_000), isOnline: true, now: now
        )
        XCTAssertEqual(result, .stream(WatchMediaRemote(url: feedURL), durationMs: 1_800_000))
    }

    func testAnAddressAloneIsNeverOfflineReady() {
        let result = WatchMediaAvailability.playability(
            currentRevision: "r1", installs: [], remote: (r1, WatchMediaRemote(url: feedURL), 1_800_000), isOnline: false, now: now
        )
        XCTAssertEqual(result, .unavailable(.offlineNotInstalled))
        XCTAssertNil(result.durationMs)
    }

    func testDisconnectedWithInstalledMediaPlaysLocally() {
        let install = WatchMediaInstall(identity: r1, fileName: "media.m4a", byteCount: 10, sha256: "x", durationMs: 1_800_000, installedAt: now)
        let result = WatchMediaAvailability.playability(currentRevision: "r1", installs: [install], remote: nil, isOnline: false, now: now)
        XCTAssertEqual(result, .local(install))
        XCTAssertEqual(result.durationMs, 1_800_000)
    }

    func testAnExpiredLinkIsUnavailable() {
        let expired = WatchMediaRemote(url: feedURL, expiresAt: now.addingTimeInterval(-1))
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r1", installs: [], remote: (r1, expired, nil), isOnline: true, now: now),
            .unavailable(.remoteExpired)
        )
    }

    func testAnOlderRevisionIsNeverPlayedForTheCurrentOne() {
        let old = WatchMediaInstall(identity: r1, fileName: "media.m4a", byteCount: 10, sha256: "x", durationMs: 1_000, installedAt: now)
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r2", installs: [old], remote: (r2, WatchMediaRemote(url: feedURL), nil), isOnline: false, now: now),
            .unavailable(.onlyOlderRevisionInstalled)
        )
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r2", installs: [old], remote: (r2, WatchMediaRemote(url: feedURL), nil), isOnline: true, now: now),
            .stream(WatchMediaRemote(url: feedURL), durationMs: nil)
        )
        // A link for the old revision doesn't count for the new one.
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r2", installs: [], remote: (r1, WatchMediaRemote(url: feedURL), nil), isOnline: true, now: now),
            .unavailable(.noSource)
        )
    }

    // MARK: - Installing on the Watch

    func testAnInterruptedTransferInstallsNothingAndTheRetryInstalls() throws {
        let margins = UnsyncedMargins()
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins)
        let (file, manifest) = try media(r1)

        let partial = try store.install(file: try truncatedCopy(of: file, bytes: 30_000), manifest: manifest, now: now)
        XCTAssertEqual(partial.status, .incomplete)
        XCTAssertTrue(store.installs(itemId: "episode-1").isEmpty)
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r1", installs: store.installs(itemId: "episode-1"), remote: nil, isOnline: false, now: now),
            .unavailable(.offlineNotInstalled),
            "a partial file never advertises a playable duration"
        )

        var corrupted = try Data(contentsOf: file)
        corrupted[500] ^= 0x55
        let corruptedURL = root.appendingPathComponent("corrupted.m4a")
        try corrupted.write(to: corruptedURL)
        XCTAssertEqual(try store.install(file: corruptedURL, manifest: manifest, now: now).status, .checksumMismatch)
        XCTAssertTrue(store.installs(itemId: "episode-1").isEmpty)

        XCTAssertEqual(try store.install(file: file, manifest: manifest, now: now).status, .installed)
        let installed = try XCTUnwrap(store.installs(itemId: "episode-1").first)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: installed)), try Data(contentsOf: file))
        XCTAssertEqual(try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins).installs(itemId: "episode-1"), [installed])
    }

    func testACrashMidInstallLeavesNothingInstalled() throws {
        let margins = UnsyncedMargins()
        _ = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins)
        let staging = mediaFolder.appendingPathComponent(".staging-\(WatchMediaStore.key(r1))-x", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(count: 10).write(to: staging.appendingPathComponent("media.m4a"))
        // Even a complete record in a folder that was never renamed into place doesn't count.
        let record = WatchMediaInstall(identity: r1, fileName: "media.m4a", byteCount: 10, sha256: "x", durationMs: 1_000, installedAt: now)
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent(WatchMediaStore.recordFileName))
        let recent = mediaFolder.appendingPathComponent(".staging-recent", isDirectory: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recent.appendingPathComponent(WatchMediaStore.recordFileName))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: staging.path)

        let reopened = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins)
        XCTAssertTrue(reopened.installs(itemId: "episode-1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "a recent one may be another store's save in progress")
    }

    func testInstallingTheSameBytesAgainChangesNothing() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (file, manifest) = try media(r1)
        XCTAssertEqual(try store.install(file: file, manifest: manifest, now: now).status, .installed)
        let first = store.installs(itemId: "episode-1")
        let again = try store.install(file: file, manifest: manifest, now: now.addingTimeInterval(60))
        XCTAssertEqual(again, WatchMediaInstallAcknowledgement(identity: r1, sha256: manifest.sha256, status: .alreadyInstalled))
        XCTAssertEqual(store.installs(itemId: "episode-1"), first)
    }

    func testANewRevisionReplacesTheOldOnlyOnceItsMarginsAreSynced() throws {
        let margins = UnsyncedMargins()
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins)
        let (oldFile, oldManifest) = try media(r1, seed: 1)
        _ = try store.install(file: oldFile, manifest: oldManifest, now: now)
        margins.revisions = ["episode-1@r1"]

        let (newFile, newManifest) = try media(r2, seed: 2)
        XCTAssertEqual(try store.install(file: newFile, manifest: newManifest, now: now.addingTimeInterval(10)).status, .installed)
        XCTAssertEqual(store.installs(itemId: "episode-1").map(\.identity), [r2, r1], "r1 stays while its Margins are unsynced")
        XCTAssertThrowsError(try store.evict(r1)) { XCTAssertEqual($0 as? WatchMediaStoreError, .unsyncedMargins) }

        margins.revisions = []
        try store.evict(r1)
        XCTAssertEqual(store.installs(itemId: "episode-1").map(\.identity), [r2])
        XCTAssertEqual(
            WatchMediaAvailability.playability(currentRevision: "r2", installs: store.installs(itemId: "episode-1"), remote: nil, isOnline: false, now: now).durationMs,
            1_800_000
        )
    }

    func testAReplacedRevisionWithSyncedMarginsGoesAtInstall() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (oldFile, oldManifest) = try media(r1, seed: 1)
        _ = try store.install(file: oldFile, manifest: oldManifest, now: now)
        let (newFile, newManifest) = try media(r2, seed: 2)
        _ = try store.install(file: newFile, manifest: newManifest, now: now.addingTimeInterval(10))
        XCTAssertEqual(store.installs(itemId: "episode-1").map(\.identity), [r2])
    }

    func testNewBytesForTheSameRevisionSwapInPlace() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (firstFile, firstManifest) = try media(r1, seed: 1)
        _ = try store.install(file: firstFile, manifest: firstManifest, now: now)
        let (secondFile, secondManifest) = try media(r1, bytes: 70_000, seed: 9)
        XCTAssertEqual(try store.install(file: secondFile, manifest: secondManifest, now: now).status, .installed)
        let installed = try XCTUnwrap(store.installs(itemId: "episode-1").first)
        XCTAssertEqual(installed.byteCount, 70_000)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: installed)), try Data(contentsOf: secondFile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mediaFolder.path).count, 1, "the old bytes are gone")
    }

    func testNewBytesForTheSameRevisionWaitWhileItsMarginsAreUnsynced() throws {
        let margins = UnsyncedMargins()
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: margins)
        let (firstFile, firstManifest) = try media(r1, seed: 1)
        _ = try store.install(file: firstFile, manifest: firstManifest, now: now)
        margins.revisions = ["episode-1@r1"]
        let (secondFile, secondManifest) = try media(r1, bytes: 70_000, seed: 9)
        let held = try store.install(file: secondFile, manifest: secondManifest, now: now)
        XCTAssertEqual(held.status, .heldForUnsyncedMargins)
        let installed = try XCTUnwrap(store.installs(itemId: "episode-1").first)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: installed)), try Data(contentsOf: firstFile), "the Margins' audio is unchanged")

        var ledger = WatchMediaDeliveryLedger()
        ledger.recordSent(secondManifest)
        XCTAssertEqual(ledger.apply(held), .needsResend)
    }

    func testAStopBetweenInstallingNewBytesAndRemovingTheOldKeepsTheNewer() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (firstFile, firstManifest) = try media(r1, seed: 1)
        _ = try store.install(file: firstFile, manifest: firstManifest, now: now)
        let first = try XCTUnwrap(store.installs(itemId: "episode-1").first)
        // Keep a copy of the old folder, as if the phone stopped before removing it.
        let oldFolder = store.fileURL(for: first).deletingLastPathComponent()
        let kept = root.appendingPathComponent("kept", isDirectory: true)
        try FileManager.default.copyItem(at: oldFolder, to: kept)
        let (secondFile, secondManifest) = try media(r1, bytes: 70_000, seed: 9)
        _ = try store.install(file: secondFile, manifest: secondManifest, now: now.addingTimeInterval(5))
        try FileManager.default.moveItem(at: kept, to: oldFolder)

        let reopened = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        XCTAssertEqual(reopened.installs(itemId: "episode-1").map(\.byteCount), [70_000])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
    }

    func testABadFileExtensionIsRefused() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (file, original) = try media(r1)
        var manifest = original
        manifest.fileExtension = "m4a/../../x"
        XCTAssertThrowsError(try store.install(file: file, manifest: manifest, now: now)) {
            XCTAssertEqual($0 as? WatchMediaStoreError, .invalidFileExtension("m4a/../../x"))
        }
        XCTAssertTrue(store.installs(itemId: "episode-1").isEmpty)
    }

    // MARK: - The phone's view of what the Watch installed

    func testRepeatedOrLateAcknowledgementsNeverMarkIncompleteMediaInstalled() throws {
        let store = try WatchMediaStore(directory: mediaFolder, unsyncedMargins: UnsyncedMargins())
        let (file, manifest) = try media(r1)
        var ledger = WatchMediaDeliveryLedger()
        ledger.recordSent(manifest)

        let partial = try store.install(file: try truncatedCopy(of: file, bytes: 1_000), manifest: manifest, now: now)
        XCTAssertEqual(ledger.apply(partial), .needsResend)
        XCTAssertEqual(ledger.apply(partial), .needsResend, "repeating it changes nothing")
        XCTAssertFalse(ledger.isInstalled(r1))

        // An "installed" for other bytes (an earlier render) doesn't count.
        XCTAssertEqual(ledger.apply(WatchMediaInstallAcknowledgement(identity: r1, sha256: "earlier-bytes", status: .installed)), .needsResend)
        // Nor does one for another revision.
        XCTAssertNil(ledger.apply(WatchMediaInstallAcknowledgement(identity: r2, sha256: manifest.sha256, status: .installed)))

        ledger.recordSent(manifest)
        let good = try store.install(file: file, manifest: manifest, now: now)
        XCTAssertEqual(ledger.apply(good), .installed)
        XCTAssertEqual(ledger.apply(partial), .installed, "a late failure from the first attempt doesn't undo it")
        XCTAssertEqual(ledger.apply(try store.install(file: file, manifest: manifest, now: now)), .installed)

        let decoded = try JSONDecoder().decode(WatchMediaDeliveryLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    // MARK: - Two-device position reconciliation

    private func report(
        _ device: String, _ positionMs: Int, sequence: Int, seek: Bool = false, at seconds: TimeInterval, revision: String = "r1"
    ) -> WatchPositionReport {
        WatchPositionReport(
            deviceId: device, playbackSessionId: "\(device)-session", itemId: "episode-1", sourceRevision: revision,
            positionMs: positionMs, sequence: sequence, isExplicitSeek: seek, reportedAt: now.addingTimeInterval(seconds)
        )
    }

    func testABackwardSeekBeatsStaleProgressFurtherAlong() {
        var positions = WatchPositionReconciler(itemId: "episode-1")
        XCTAssertEqual(positions.apply(report("watch", 2_400_000, sequence: 1, at: 0), currentRevision: "r1"), .accepted)
        // The listener seeks back on the phone.
        XCTAssertEqual(positions.apply(report("phone", 600_000, sequence: 1, seek: true, at: 100), currentRevision: "r1"), .accepted)
        // The Watch reconnects and delivers progress queued before the seek: further along, but stale.
        XCTAssertEqual(positions.apply(report("watch", 2_460_000, sequence: 2, at: 60), currentRevision: "r1"), .ignored(.progressBeforeSeek))
        XCTAssertEqual(positions.apply(report("watch", 2_470_000, sequence: 3, at: 101), currentRevision: "r1"), .ignored(.progressBeforeSeek))
        XCTAssertEqual(positions.current?.positionMs, 600_000)
        XCTAssertEqual(positions.current?.deviceId, "phone")

        // Progress the Watch clearly made after the seek is the listener carrying on there.
        XCTAssertEqual(positions.apply(report("watch", 640_000, sequence: 4, at: 140), currentRevision: "r1"), .accepted)
        XCTAssertEqual(positions.current?.positionMs, 640_000)
    }

    func testStaleProgressCantOverrideASeekAfterLaterProgressReplacedIt() {
        var positions = WatchPositionReconciler(itemId: "episode-1")
        _ = positions.apply(report("watch", 2_400_000, sequence: 1, at: 0), currentRevision: "r1")
        XCTAssertEqual(positions.apply(report("phone", 600_000, sequence: 1, seek: true, at: 100), currentRevision: "r1"), .accepted)
        XCTAssertEqual(positions.apply(report("phone", 600_500, sequence: 2, at: 100.5), currentRevision: "r1"), .accepted)
        // Watch progress from before the seek, stamped a little later by a fast clock.
        XCTAssertEqual(positions.apply(report("watch", 2_470_000, sequence: 2, at: 101), currentRevision: "r1"), .ignored(.progressBeforeSeek))
        XCTAssertEqual(positions.current?.positionMs, 600_500)
    }

    func testOneDevicesReportsApplyInItsOwnOrder() {
        var positions = WatchPositionReconciler(itemId: "episode-1")
        _ = positions.apply(report("watch", 300_000, sequence: 5, at: 50), currentRevision: "r1")
        XCTAssertEqual(positions.apply(report("watch", 900_000, sequence: 4, at: 40), currentRevision: "r1"), .ignored(.outOfOrder))
        XCTAssertEqual(positions.apply(report("watch", 300_000, sequence: 5, at: 50), currentRevision: "r1"), .ignored(.outOfOrder))
        // Its own backward seek, later in its order, stands even with an earlier clock.
        XCTAssertEqual(positions.apply(report("watch", 100_000, sequence: 6, seek: true, at: 49), currentRevision: "r1"), .accepted)
        XCTAssertEqual(positions.current?.positionMs, 100_000)
    }

    func testPositionsFromAnotherRevisionAreNeverApplied() {
        var positions = WatchPositionReconciler(itemId: "episode-1")
        _ = positions.apply(report("phone", 100_000, sequence: 1, at: 0, revision: "r2"), currentRevision: "r2")
        XCTAssertEqual(positions.apply(report("watch", 900_000, sequence: 1, at: 50, revision: "r1"), currentRevision: "r2"), .ignored(.otherRevision))
        XCTAssertEqual(positions.current?.sourceRevision, "r2")
        XCTAssertEqual(positions.current?.positionMs, 100_000)
    }

    func testTheReconcilerSurvivesARoundTripWithDeviceAndSessionIdentity() throws {
        var positions = WatchPositionReconciler(itemId: "episode-1")
        _ = positions.apply(report("watch", 300_000, sequence: 2, at: 50), currentRevision: "r1")
        let decoded = try JSONDecoder().decode(WatchPositionReconciler.self, from: JSONEncoder().encode(positions))
        XCTAssertEqual(decoded, positions)
        XCTAssertEqual(decoded.current?.playbackSessionId, "watch-session")
        var restored = decoded
        XCTAssertEqual(restored.apply(report("watch", 900_000, sequence: 2, at: 60), currentRevision: "r1"), .ignored(.outOfOrder))
    }
}
