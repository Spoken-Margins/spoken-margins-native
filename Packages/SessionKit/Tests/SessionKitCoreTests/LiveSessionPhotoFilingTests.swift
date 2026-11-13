import Foundation
import XCTest
@testable import SessionKit

/// #2708 PR 2: filing a photo Margin through the file worker, on real temporary directories. A picture's bytes are
/// stand-ins here, because filing never looks inside a photo.
final class LiveSessionPhotoFilingTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var temp: URL!
    private var staging: LiveSessionPhotoStore!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let bytes = Data(repeating: 0xAB, count: 4_096)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "photo-filing-\(UUID().uuidString)")
        root = base.appending(path: "support")
        temp = base.appending(path: "tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        staging = LiveSessionPhotoStore(root: root, temporaryRoot: temp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func stage() throws -> LiveSessionPhotoStore.Staged {
        try staging.stage(data: bytes, widthPx: 800, heightPx: 600)
    }

    /// Stages a photo and keeps it for `margin` the way a written Margin's save does.
    private func commit(_ worker: LiveSessionFileWorker, margin: String) async throws -> LiveSessionPhoto {
        let staged = try stage()
        let photo = await worker.commitPhoto(staged, sessionId: "live", marginId: margin)
        return try XCTUnwrap(photo)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func startSession(_ worker: LiveSessionFileWorker, kind: ElsewhereKind = .paper) async throws {
        try await worker.save(LiveSession(id: "live", kind: kind, title: "Book", startedAt: start), generation: 1)
    }

    // MARK: Filing

    func testTheFileIsInPlaceBeforeTheMarginThatNamesItIsSaved() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await startSession(worker)
        let staged = try stage()

        let filed = await worker.attachSpokenMargin(
            sessionId: "live", marginId: "phone-1", audioPath: "SpokenMargins/interjections/a.m4a", markedAt: start.addingTimeInterval(10),
            durationMs: 4_000, spokenOn: "phone", staged: staged)

        XCTAssertFalse(filed.photoFailed)
        let margin = try XCTUnwrap(filed.session?.margins.first)
        let photo = try XCTUnwrap(margin.validPhoto)
        let url = try XCTUnwrap(LiveSessionPhotoStore(root: root).fileURL(for: photo))
        XCTAssertTrue(exists(url), "the Margin names a photo that is on disk")
        XCTAssertFalse(exists(staged.url), "the staged copy moved, it was not copied")
        // And it is what was saved, not only what was returned.
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.first?.photo, photo)
    }

    func testAFailedMoveSavesTheMarginWithoutAPhotoAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await startSession(worker)
        let staged = try stage()
        try FileManager.default.removeItem(at: staged.url) // the system cleared the temporary folder

        let filed = await worker.attachSpokenMargin(
            sessionId: "live", marginId: "phone-1", audioPath: "SpokenMargins/interjections/a.m4a", markedAt: start.addingTimeInterval(10),
            durationMs: 4_000, spokenOn: "phone", staged: staged)

        XCTAssertTrue(filed.photoFailed)
        let margin = try XCTUnwrap(filed.session?.margins.first, "the listener's words are never lost to the picture")
        XCTAssertNil(margin.photo)
        XCTAssertEqual(margin.audioPath, "SpokenMargins/interjections/a.m4a")
    }

    func testAMarginThatCannotBeSavedLeavesNoPhotoBehind() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await startSession(worker)
        await worker.discard(sessionId: "live", generation: 5) // the session was discarded while the listener recorded
        let staged = try stage()

        let filed = await worker.attachSpokenMargin(
            sessionId: "live", marginId: "phone-1", audioPath: "SpokenMargins/interjections/a.m4a", markedAt: start.addingTimeInterval(10),
            durationMs: 4_000, spokenOn: "phone", staged: staged)

        XCTAssertNil(filed.session)
        let photos = root.appending(path: LiveSessionPhoto.folder)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: photos.path)) ?? []
        XCTAssertEqual(left, [], "nothing under live-photos names a Margin that was never saved")
        XCTAssertFalse(exists(staged.url))
    }

    func testAMarginAlreadyFiledUnderThatIdKeepsItsOwnPhoto() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await startSession(worker)
        let first = await worker.attachSpokenMargin(
            sessionId: "live", marginId: "phone-1", audioPath: "a.m4a", markedAt: start.addingTimeInterval(10),
            durationMs: 1_000, spokenOn: "phone", staged: try stage())
        let kept = try XCTUnwrap(first.session?.margins.first?.photo)

        let again = await worker.attachSpokenMargin(
            sessionId: "live", marginId: "phone-1", audioPath: "a.m4a", markedAt: start.addingTimeInterval(10),
            durationMs: 1_000, spokenOn: "phone", staged: try stage())

        XCTAssertNil(again.session)
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.first?.photo, kept)
        let url = try XCTUnwrap(LiveSessionPhotoStore(root: root).fileURL(for: kept))
        XCTAssertTrue(exists(url), "the second attempt must not delete the first one's photo")
    }

    // MARK: Written Margins and deleting

    func testCommitPhotoGivesTheReferenceAWrittenMarginKeeps() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let photo = await worker.commitPhoto(try stage(), sessionId: "live", marginId: "m1")
        let kept = try XCTUnwrap(photo)
        XCTAssertEqual(kept.path, LiveSessionPhotoStore.relativePath(sessionId: "live", marginId: "m1"))
        XCTAssertTrue(exists(try XCTUnwrap(LiveSessionPhotoStore(root: root).fileURL(for: kept))))
    }

    func testCommitPhotoForAClearedFileGivesNilAndLeavesNothing() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let staged = try stage()
        try FileManager.default.removeItem(at: staged.url)
        let photo = await worker.commitPhoto(staged, sessionId: "live", marginId: "m1")
        XCTAssertNil(photo)
    }

    func testDeletingAMarginRemovesItsPhotoAndDiscardingTheSessionRemovesTheFolder() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await startSession(worker)
        let one = try await commit(worker, margin: "m1")
        let two = try await commit(worker, margin: "m2")
        let store = LiveSessionPhotoStore(root: root)

        await worker.removePhoto(one)
        XCTAssertFalse(exists(try XCTUnwrap(store.fileURL(for: one))))
        XCTAssertTrue(exists(try XCTUnwrap(store.fileURL(for: two))), "only that Margin's photo goes")

        await worker.discard(sessionId: "live", generation: 3)
        XCTAssertFalse(exists(try XCTUnwrap(store.fileURL(for: two))), "a discarded session takes its photos with it")
    }

    // MARK: The launch sweep through the worker

    func testTheLaunchSweepRemovesOnlyAPhotoNoMarginNames() async throws {
        let worker = LiveSessionFileWorker(root: root)
        var session = LiveSession(id: "live", kind: .paper, title: "Book", startedAt: start)
        let named = try await commit(worker, margin: "named")
        var margin = session.margin(id: "named", text: "words", markedAt: start.addingTimeInterval(5))
        margin.photo = named
        session.margins = [margin]
        try await worker.save(session, generation: 1)
        // A crash between the move and the save left this one.
        let orphan = try await commit(worker, margin: "orphan")
        let store = LiveSessionPhotoStore(root: root)

        let result = await worker.sweepPhotos()

        XCTAssertEqual(result?.removedFiles, [orphan.path])
        XCTAssertTrue(exists(try XCTUnwrap(store.fileURL(for: named))))
        XCTAssertFalse(exists(try XCTUnwrap(store.fileURL(for: orphan))))
    }

    func testAWorkerWithNoRootHasNothingToSweepOrKeep() async throws {
        let worker = LiveSessionFileWorker(root: nil)
        let sweep = await worker.sweepPhotos()
        let kept = await worker.commitPhoto(try stage(), sessionId: "live", marginId: "m1")
        XCTAssertNil(sweep)
        XCTAssertNil(kept)
    }
}
