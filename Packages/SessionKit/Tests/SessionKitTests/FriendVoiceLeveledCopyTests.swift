#if canImport(AVFoundation)
import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SessionKitAudio

/// #3406: the leveled playback copy of a friend's voice leaves with the voice. The copy is found by the recording's
/// content, so it has to go while the file can still be read: row delete, then the copy, then the folder.
final class FriendVoiceLeveledCopyTests: XCTestCase {
    private var root: URL!
    private var incoming: URL!
    private var cacheFolder: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("friend-voice-\(UUID().uuidString)")
        incoming = root.appendingPathComponent("SpokenMargins/IncomingPackages", isDirectory: true)
        cacheFolder = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func copies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "caf" }
    }

    /// A friend's packet on item "a" whose Margin voice has been leveled, as opening the item does.
    private func importedAndLeveled(cache: LeveledMarginCache) async throws -> String {
        let folder = UUID().uuidString
        let voice = incoming.appendingPathComponent("\(folder)/assets/voice.wav")
        try FileManager.default.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MarginLoudnessLevelerTests.write([MarginLoudnessLevelerTests.speechLike(seed: 7, lufs: -35)], to: voice, aac: false)
        let identity = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A")
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: "layer", itemId: "a", packageDigest: "digest", packageId: "packet", itemIdentity: identity,
            displayLabel: "Friend", importedAt: Date(), sourceResolutionStatus: .contextOnly, isEnabled: true, isMuted: false))
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "margin", layerId: "layer", packageScopedId: "margin-001", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Hi", audioPath: voice.path, audioDurationMs: 500,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 9_000)))
        guard case .leveled = await cache.level(voice) else { throw XCTSkip("leveling did not produce a copy") }
        XCTAssertEqual(copies().count, 1)
        return folder
    }

    func testTheLeveledCopyOfAFriendsVoiceGoesWithTheFolder() async throws {
        let cache = LeveledMarginCache(directory: cacheFolder)
        let folder = try await importedAndLeveled(cache: cache)

        let removal = try FriendPacketFolders.deleting(
            itemIds: ["a"], store: store, directory: incoming, keeping: [],
            beforeRemovingFile: { cache.removeCopies(of: $0) }
        ) { try store.deleteItem(id: "a") }
        _ = await removal.value
        cache.waitForQueuedWork()

        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent(folder).path))
        XCTAssertEqual(copies(), [], "no derived copy of the friend's voice outlives it")
    }

    func testTheCopyStaysWhenTheRowDeleteFails() async throws {
        let cache = LeveledMarginCache(directory: cacheFolder)
        let folder = try await importedAndLeveled(cache: cache)

        struct Refused: Error {}
        XCTAssertThrowsError(try FriendPacketFolders.deleting(
            itemIds: ["a"], store: store, directory: incoming, keeping: [],
            beforeRemovingFile: { cache.removeCopies(of: $0) }
        ) { throw Refused() })
        cache.waitForQueuedWork()

        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.appendingPathComponent(folder).path))
        XCTAssertEqual(copies().count, 1)
    }
}
#endif
