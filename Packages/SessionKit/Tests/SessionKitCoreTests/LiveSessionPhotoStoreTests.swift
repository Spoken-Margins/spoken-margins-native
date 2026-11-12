import Foundation
import XCTest
@testable import SessionKit

/// #2708 PR 1: the files behind a photo Margin, on real temporary directories. The picture work is
/// `LiveSessionPhotoEncoderTests` (Mac only); here the bytes are stand-ins, because the store never looks inside a photo.
final class LiveSessionPhotoStoreTests: XCTestCase {
    private var root: URL!
    private var temp: URL!
    private var store: LiveSessionPhotoStore!
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!
    private let bytes = Data(repeating: 0xAB, count: 4_096)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "photo-store-\(UUID().uuidString)")
        root = base.appending(path: "support")
        temp = base.appending(path: "tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        store = LiveSessionPhotoStore(root: root, temporaryRoot: temp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func keep(session: String, margin: String) throws -> LiveSessionPhoto {
        let staged = try store.stage(data: bytes, widthPx: 800, heightPx: 600)
        return try store.commit(staged, sessionId: session, marginId: margin)
    }

    /// A stored session whose Margins name these photos.
    @discardableResult
    private func save(session id: String, naming photos: [(margin: String, photo: LiveSessionPhoto?)], in collection: LiveSessionCollection) throws -> LiveSession {
        var live = LiveSession(id: id, kind: .paper, title: "Book", startedAt: start, endedAt: nil, startPositionMs: 0)
        live.margins = photos.map { entry in
            var margin = live.margin(id: entry.margin, text: "words", markedAt: start.addingTimeInterval(5))
            margin.photo = entry.photo
            return margin
        }
        try collection.save(live)
        return live
    }

    /// A photo reference as a hand-edited or damaged session file would decode it (decoding does not enforce the rules).
    private func edited(_ photo: LiveSessionPhoto, _ changes: [String: Any]) throws -> LiveSessionPhoto {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as? [String: Any])
        for (key, value) in changes { object[key] = value }
        let damaged = try JSONDecoder().decode(LiveSessionPhoto.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(damaged.isWithinRules, "fixture edit failed")
        return damaged
    }

    // MARK: Paths

    func testPathsAreValidForPlainAndAwkwardIds() {
        for (session, margin) in [("s1", "m1"), ("A-b_C", "9f8e7d"), ("../../etc", "x/y"), ("séance ✓", "m 1"), (String(repeating: "x", count: 500), "m"),
                                  ("a%2e%2e", "a\\b"), ("line\nbreak", "tab\t")] {
            let path = LiveSessionPhotoStore.relativePath(sessionId: session, marginId: margin)
            XCTAssertTrue(LiveSessionPhoto.isValid(path: path), "\(session) \(margin) → \(path)")
            XCTAssertTrue(path.hasPrefix("SpokenMargins/live-photos/"), path)
        }
    }

    func testTwoIdsNeverShareAPath() {
        let ids = ["a/b", "a_b", "a b", "a\\b", "A/B", "a/b ", "../a", "..a"]
        let paths = Set(ids.map { LiveSessionPhotoStore.relativePath(sessionId: $0, marginId: "m") })
        XCTAssertEqual(paths.count, ids.count)
        XCTAssertEqual(LiveSessionPhotoStore.relativePath(sessionId: "s1", marginId: "m1"), "SpokenMargins/live-photos/s1/m1.jpg")
    }

    // MARK: Stage, commit, discard

    func testStagingWritesToTheTemporaryFolderOnlyAndCommitMovesIt() throws {
        let staged = try store.stage(data: bytes, widthPx: 4, heightPx: 3)
        XCTAssertTrue(staged.url.path.hasPrefix(temp.path), staged.url.path)
        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        XCTAssertFalse(exists(root.appending(path: LiveSessionPhoto.folder)), "nothing under live-photos before Save")

        let photo = try store.commit(staged, sessionId: "s1", marginId: "m1")
        XCTAssertEqual(photo.path, "SpokenMargins/live-photos/s1/m1.jpg")
        XCTAssertEqual([photo.widthPx, photo.heightPx, photo.byteCount], [4, 3, bytes.count])
        XCTAssertFalse(exists(staged.url), "moved, not copied")
        let kept = try XCTUnwrap(store.fileURL(for: photo))
        XCTAssertEqual(try Data(contentsOf: kept), bytes)
        XCTAssertTrue(store.fileExists(for: photo))
    }

    func testCancelDeletesTheTemporaryFileAndKeepsNothing() throws {
        let staged = try store.stage(data: bytes, widthPx: 800, heightPx: 600)
        store.discard(staged)
        store.discard(staged)
        XCTAssertFalse(exists(staged.url))
        XCTAssertFalse(exists(root.appending(path: LiveSessionPhoto.folder)))
        XCTAssertThrowsError(try store.commit(staged, sessionId: "s1", marginId: "m1")) {
            XCTAssertEqual($0 as? LiveSessionPhotoStore.StoreError, .stagedFileMissing)
        }
    }

    func testTheCapsHold() throws {
        // Over the pixel cap, over the byte cap, no size, empty, and an extension that is not a photo's.
        XCTAssertThrowsError(try store.stage(data: bytes, widthPx: 2_049, heightPx: 10))
        XCTAssertThrowsError(try store.stage(data: bytes, widthPx: 10, heightPx: 2_049))
        XCTAssertThrowsError(try store.stage(data: Data(count: 1_500_001), widthPx: 100, heightPx: 100))
        XCTAssertThrowsError(try store.stage(data: bytes, widthPx: 0, heightPx: 100))
        XCTAssertThrowsError(try store.stage(data: Data(), widthPx: 100, heightPx: 100))
        XCTAssertThrowsError(try store.stage(data: bytes, widthPx: 100, heightPx: 100, fileExtension: "png"))
        XCTAssertThrowsError(try store.stage(data: bytes, widthPx: 100, heightPx: 100, fileExtension: "../x"))
        XCTAssertNoThrow(try store.stage(data: Data(count: 1_500_000), widthPx: 2_048, heightPx: 1_536))
        XCTAssertNoThrow(try store.stage(data: bytes, widthPx: 100, heightPx: 100, fileExtension: "HEIC"))
        // A refused picture leaves no file behind.
        let before = (try? FileManager.default.contentsOfDirectory(atPath: temp.appending(path: "live-photo-staging").path))?.count
        _ = try? store.stage(data: bytes, widthPx: 5_000, heightPx: 10)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: temp.appending(path: "live-photo-staging").path))?.count, before)
    }

    func testCommitNeverOverwritesAKeptPhoto() throws {
        let first = try keep(session: "s1", margin: "m1")
        let second = try store.stage(data: Data(repeating: 1, count: 100), widthPx: 10, heightPx: 10)
        XCTAssertThrowsError(try store.commit(second, sessionId: "s1", marginId: "m1")) {
            XCTAssertEqual($0 as? LiveSessionPhotoStore.StoreError, .alreadyKept)
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(for: first))), bytes, "the kept photo is untouched")
        XCTAssertTrue(exists(second.url), "a failed commit leaves the staged file for the caller to discard")
    }

    func testAFailedWriteLeavesTheCallerAbleToSaveTheMarginWithoutAPhoto() throws {
        // `live-photos` is a file, so the folder can't be made: commit throws, the staged file stays, nothing else changes.
        try FileManager.default.createDirectory(at: root.appending(path: "SpokenMargins"), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: root.appending(path: "SpokenMargins/live-photos"))
        let staged = try store.stage(data: bytes, widthPx: 800, heightPx: 600)
        XCTAssertThrowsError(try store.commit(staged, sessionId: "s1", marginId: "m1"))
        XCTAssertTrue(exists(staged.url))
        // The caller's path: no photo, the words are saved.
        var live = LiveSession(id: "s1", kind: .paper, title: "Book", startedAt: start, endedAt: nil, startPositionMs: 0)
        var margin = live.margin(id: "m1", text: "my words", markedAt: start.addingTimeInterval(5))
        margin.photo = (try? store.commit(staged, sessionId: "s1", marginId: "m1"))
        live.margins = [margin]
        XCTAssertNil(live.margins[0].photo)
        XCTAssertEqual(live.margins[0].text, "my words")
        store.discard(staged)
        XCTAssertFalse(exists(staged.url))
    }

    // MARK: Missing files and bad references

    func testAMissingFileIsItsOwnState() throws {
        let photo = try keep(session: "s1", margin: "m1")
        try FileManager.default.removeItem(at: XCTUnwrap(store.fileURL(for: photo)))
        XCTAssertFalse(store.fileExists(for: photo))
        XCTAssertNotNil(store.fileURL(for: photo), "the reference is still good; only the file is gone")
        // A directory where the file should be is not a photo.
        try FileManager.default.createDirectory(at: XCTUnwrap(store.fileURL(for: photo)), withIntermediateDirectories: true)
        XCTAssertFalse(store.fileExists(for: photo))
    }

    func testAReferenceThatBreaksTheRulesNeverPointsOutsideTheStore() throws {
        let good = try XCTUnwrap(LiveSessionPhoto(path: "SpokenMargins/live-photos/s1/a.jpg", widthPx: 8, heightPx: 8, byteCount: 8))
        let damaged = try edited(good, ["path": "SpokenMargins/live-photos/../../outside.jpg"])
        XCTAssertNil(store.fileURL(for: damaged))
        XCTAssertFalse(store.fileExists(for: damaged))
        try Data("keep me".utf8).write(to: root.deletingLastPathComponent().appending(path: "outside.jpg"))
        store.remove(damaged)
        XCTAssertTrue(exists(root.deletingLastPathComponent().appending(path: "outside.jpg")))
    }

    // MARK: Removing

    func testDeletingAMarginRemovesItsFileAndAnEmptyFolderOnly() throws {
        let one = try keep(session: "s1", margin: "m1")
        let two = try keep(session: "s1", margin: "m2")
        let folder = try XCTUnwrap(store.fileURL(for: one)).deletingLastPathComponent()
        store.remove(one)
        XCTAssertFalse(store.fileExists(for: one))
        XCTAssertTrue(store.fileExists(for: two))
        XCTAssertTrue(exists(folder))
        store.remove(two)
        XCTAssertFalse(exists(folder), "the last photo takes the empty folder with it")
        store.remove(two)
    }

    func testDeletingASessionRemovesItsFolderAndNoOthers() throws {
        let mine = try keep(session: "s1", margin: "m1")
        _ = try keep(session: "s1", margin: "m2")
        let other = try keep(session: "s2", margin: "m1")
        store.removeFolder(sessionId: "s1")
        XCTAssertFalse(store.fileExists(for: mine))
        XCTAssertTrue(store.fileExists(for: other))
        store.removeFolder(sessionId: "never-had-photos")
        store.removeFolder(sessionId: "../s2")
        XCTAssertTrue(store.fileExists(for: other), "an id that looks like a path is cleaned, not followed")
    }

    // MARK: The launch sweep

    func testTheSweepRemovesOnlyFilesNoMarginNames() throws {
        let collection = LiveSessionCollection(root: root)
        let named = try keep(session: "s1", margin: "m1")
        let unnamed = try keep(session: "s1", margin: "crashed")
        let otherSessionUnnamed = try keep(session: "s2", margin: "x")
        let fromOtherNamed = try keep(session: "s3", margin: "y")
        try save(session: "s1", naming: [("m1", named), ("m2", nil)], in: collection)
        try save(session: "s2", naming: [], in: collection)
        try save(session: "s3", naming: [("y", fromOtherNamed)], in: collection)

        let result = store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertEqual(result.removedFiles.sorted(), ["SpokenMargins/live-photos/s1/crashed.jpg", "SpokenMargins/live-photos/s2/x.jpg"])
        XCTAssertTrue(store.fileExists(for: named))
        XCTAssertTrue(store.fileExists(for: fromOtherNamed))
        XCTAssertFalse(store.fileExists(for: unnamed))
        XCTAssertFalse(store.fileExists(for: otherSessionUnnamed))
        XCTAssertFalse(exists(root.appending(path: "SpokenMargins/live-photos/s2")), "an emptied folder goes")
        // A second sweep has nothing to do.
        XCTAssertEqual(store.sweep(readable: collection.loadAll(), in: collection), LiveSessionPhotoStore.SweepResult())
    }

    func testTheSweepCleansTheFolderOfASessionThatIsStillRunning() throws {
        let collection = LiveSessionCollection(root: root)
        let named = try keep(session: "running", margin: "m1")
        let crashed = try keep(session: "running", margin: "m2")
        try save(session: "running", naming: [("m1", named)], in: collection)
        XCTAssertNil(collection.loadAll().first?.endedAt, "still running")
        store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertTrue(store.fileExists(for: named))
        XCTAssertFalse(store.fileExists(for: crashed))
    }

    func testTheSweepSparesEverythingUnderAFolderItCannotRead() throws {
        let collection = LiveSessionCollection(root: root)
        let readable = try keep(session: "good", margin: "gone")
        let plain = try keep(session: "broken", margin: "m1")
        let awkward = try keep(session: "séance ✓/1", margin: "m1")
        try save(session: "good", naming: [], in: collection)
        // Their session files exist and do not decode: the Margins that name these photos may be inside them.
        try collection.save(LiveSession(id: "broken", kind: .paper, title: "t", startedAt: start, endedAt: nil, startPositionMs: 0))
        try collection.save(LiveSession(id: "séance ✓/1", kind: .paper, title: "t", startedAt: start, endedAt: nil, startPositionMs: 0))
        try Data("{ not json".utf8).write(to: collection.url(for: "broken"))
        try Data("{ not json".utf8).write(to: collection.url(for: "séance ✓/1"))
        XCTAssertEqual(collection.loadAll().map(\.id), ["good"])

        let result = store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertFalse(store.fileExists(for: readable))
        XCTAssertTrue(store.fileExists(for: plain))
        XCTAssertTrue(store.fileExists(for: awkward))
        XCTAssertEqual(result.protectedFolders.count, 2)
        XCTAssertEqual(result.removedFiles, ["SpokenMargins/live-photos/good/gone.jpg"])
    }

    func testTheSweepDoesNothingWhenItCannotSeeTheSessionStore() throws {
        let collection = LiveSessionCollection(root: root)
        let photo = try keep(session: "s1", margin: "m1")
        // No Sessions folder at all (not listable): every photo might be named by something it cannot read.
        let result = store.sweep(readable: [], in: collection)
        XCTAssertTrue(result.skipped)
        XCTAssertTrue(store.fileExists(for: photo))
    }

    func testTheSweepLeavesWhatItDoesNotOwn() throws {
        let collection = LiveSessionCollection(root: root)
        try save(session: "s1", naming: [], in: collection)
        let folder = root.appending(path: "SpokenMargins/live-photos/s1")
        try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appending(path: "nested/inside.jpg"))
        try Data("x".utf8).write(to: root.appending(path: "SpokenMargins/live-photos/loose.jpg"))
        try Data("x".utf8).write(to: root.appending(path: "SpokenMargins/interjections-recording.m4a"))
        store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertTrue(exists(folder.appending(path: "nested/inside.jpg")), "only regular files directly in a session folder are swept")
        XCTAssertTrue(exists(root.appending(path: "SpokenMargins/live-photos/loose.jpg")))
        XCTAssertTrue(exists(root.appending(path: "SpokenMargins/interjections-recording.m4a")))
    }

    func testTheSweepKeepsAPathAMarginNamesEvenWhenItBreaksTheRules() throws {
        let collection = LiveSessionCollection(root: root)
        let photo = try keep(session: "s1", margin: "m1")
        // A hand-edited size: the reference no longer keeps the rules, the file is still named.
        let odd = try edited(photo, ["byteCount": 99_000_000])
        try save(session: "s1", naming: [("m1", odd)], in: collection)
        store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertTrue(store.fileExists(for: photo))
    }

    func testTheSweepClearsStagedPhotosFromAnEarlierLaunch() throws {
        let collection = LiveSessionCollection(root: root)
        try save(session: "s1", naming: [], in: collection)
        let staged = try store.stage(data: bytes, widthPx: 800, heightPx: 600)
        let neighbour = temp.appending(path: "somebody-elses.tmp")
        try Data("x".utf8).write(to: neighbour)
        let result = store.sweep(readable: collection.loadAll(), in: collection)
        XCTAssertEqual(result.clearedStaged, 1)
        XCTAssertFalse(exists(staged.url))
        XCTAssertTrue(exists(neighbour), "only our own staging folder is cleared")
    }

    // MARK: Relaunch and older builds

    func testARelaunchFindsTheMarginItsPhotoReferenceAndTheFile() throws {
        let collection = LiveSessionCollection(root: root)
        let photo = try keep(session: "s1", margin: "m1")
        try save(session: "s1", naming: [("m1", photo)], in: collection)

        // A new store and a new collection over the same folders, as after a relaunch.
        let relaunched = LiveSessionPhotoStore(root: root, temporaryRoot: temp)
        let loaded = try XCTUnwrap(LiveSessionCollection(root: root).loadAll().first?.margins.first)
        let reference = try XCTUnwrap(loaded.validPhoto)
        XCTAssertEqual(reference, photo)
        XCTAssertTrue(relaunched.fileExists(for: reference))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(relaunched.fileURL(for: reference))), bytes)
        XCTAssertEqual(loaded.photoAltText, "Photo with Margin: words")
    }

    /// What Builds 32 and 34 do with a session file written with a photo: they decode the keys they know and ignore
    /// `photo`. The stand-in below has only the keys an earlier build has.
    func testAnEarlierBuildReadsASessionWrittenWithAPhoto() throws {
        struct EarlierMargin: Decodable { var id: String; var text: String }
        struct EarlierSession: Decodable { var id: String; var margins: [EarlierMargin] }
        let collection = LiveSessionCollection(root: root)
        let photo = try keep(session: "s1", margin: "m1")
        try save(session: "s1", naming: [("m1", photo)], in: collection)
        let data = try Data(contentsOf: collection.url(for: "s1"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"photo\""), "fixture must carry a photo")
        let earlier = try JSONDecoder().decode(EarlierSession.self, from: data)
        XCTAssertEqual(earlier.margins.map(\.id), ["m1"])
        XCTAssertEqual(earlier.margins.first?.text, "words")
    }
}
