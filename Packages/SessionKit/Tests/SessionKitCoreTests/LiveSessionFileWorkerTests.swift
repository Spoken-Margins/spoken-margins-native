import Foundation
import XCTest
@testable import SessionKit

/// #2487, #2256: the live session's disk work runs on `LiveSessionFileWorker`, off the main thread. These use real
/// files in a temporary Application Support stand-in.
final class LiveSessionFileWorkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-worker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dropInInbox(_ worker: LiveSessionFileWorker, id: String, at offset: TimeInterval) throws -> WatchMarginTransfer {
        let transfer = WatchMarginTransfer(id: id, wallStart: t0.addingTimeInterval(offset), durationMs: 2_000)
        let received = root.appending(path: "received-\(id).m4a")
        try Data("audio-\(id)".utf8).write(to: received)
        try worker.storeIncoming(fileAt: received, transfer: transfer)
        return transfer
    }

    func testAnOlderSaveArrivingLateNeverOverwritesANewerOne() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let newer = LiveSession(id: "live", title: "newer", startedAt: t0)
        let older = LiveSession(id: "live", title: "older", startedAt: t0)
        let wroteNewer = try await worker.save(newer, generation: 2)
        let wroteOlder = try await worker.save(older, generation: 1)
        XCTAssertTrue(wroteNewer)
        XCTAssertFalse(wroteOlder)
        let loaded = await worker.load()
        XCTAssertEqual(loaded?.title, "newer")
    }

    func testAStaleSaveDoesNotBringBackADiscardedSession() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 1)
        await worker.remove(generation: 3)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 2)
        let loaded = await worker.load()
        XCTAssertNil(loaded)
    }

    func testAWatchMarginIsFiledOnceAndItsRecordingMovedIntoPlace() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 1)
        let transfer = try dropInInbox(worker, id: "abc", at: 30)

        let filed = await worker.fileWatchInbox()
        XCTAssertEqual(filed, [.init(marginId: transfer.marginId, audioPath: transfer.audioPath)])
        let destination = try XCTUnwrap(worker.recordingURL(for: transfer.audioPath))
        XCTAssertEqual(try Data(contentsOf: destination), Data("audio-abc".utf8))
        let inbox = try XCTUnwrap(worker.inboxDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let stored = await worker.load()
        XCTAssertEqual(stored?.margins.map(\.id), [transfer.marginId])

        _ = try dropInInbox(worker, id: "abc", at: 30) // WatchConnectivity delivered it again
        let again = await worker.fileWatchInbox()
        XCTAssertEqual(again, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let storedAgain = await worker.load()
        XCTAssertEqual(storedAgain?.margins.count, 1)
    }

    func testAWatchMarginWithNoSessionWaitsInTheInbox() async throws {
        let worker = LiveSessionFileWorker(root: root)
        _ = try dropInInbox(worker, id: "early", at: 0)
        let filed = await worker.fileWatchInbox()
        XCTAssertEqual(filed, [])
        let inbox = try XCTUnwrap(worker.inboxDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted(), ["watch-early.json", "watch-early.m4a"])
    }

    /// The screen saves its own copy, which can't yet hold a Watch Margin or transcript the worker just filed.
    /// That save must not drop them before the screen takes them in.
    func testAScreenSaveRacingTheReconcileKeepsTheWatchMarginAndItsWords() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let screen = LiveSession(id: "live", startedAt: t0, margins: [LiveSessionMargin(id: "typed", text: "hi", markedAt: t0)])
        try await worker.save(screen, generation: 1)
        let transfer = try dropInInbox(worker, id: "w1", at: 10)
        _ = await worker.fileWatchInbox()
        let id = transfer.marginId
        await worker.update { $0.setTranscript("spoken words", forMarginId: id) }

        try await worker.save(screen, generation: 2) // the screen's copy, without the Watch Margin
        let stored = await worker.load()
        XCTAssertEqual(stored?.margins.map(\.id), ["typed", transfer.marginId])
        XCTAssertEqual(stored?.margins.last?.text, "spoken words")

        // Once the screen's copy carries the Margin, the listener's own changes win.
        var tookIn = try XCTUnwrap(stored)
        tookIn.margins.removeAll { $0.id == transfer.marginId }
        try await worker.save(try XCTUnwrap(stored), generation: 3)
        try await worker.save(tookIn, generation: 4)
        let afterRemove = await worker.load()
        XCTAssertEqual(afterRemove?.margins.map(\.id), ["typed"])
    }
}
