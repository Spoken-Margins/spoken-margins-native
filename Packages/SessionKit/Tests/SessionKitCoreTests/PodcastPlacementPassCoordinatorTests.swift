import Foundation
import XCTest
@testable import SessionKit

final class PodcastPlacementPassCoordinatorTests: XCTestCase {
    @MainActor
    func testThreeRequestsForTheSameItemAndFileJoinAndWriteOnce() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = PodcastPlacementPassCoordinator()
        let request = PodcastPlacementPassCoordinator.Request(itemId: "episode", file: try PodcastPlacementFile(url: file), layers: [])
        let probe = PlacementProbe()
        let first = coordinator.schedule(request) { context in await probe.run(context) }
        let second = coordinator.schedule(request) { context in await probe.run(context) }
        let third = coordinator.schedule(request) { context in await probe.run(context) }
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, third.id)
        XCTAssertTrue(second.joined)
        XCTAssertTrue(third.joined)
        await probe.release()
        await first.completion.value
        await second.completion.value
        await third.completion.value
        let writes = await probe.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testReplacingTheFileCancelsTheOldPassAndStopsItsWrite() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = PodcastPlacementPassCoordinator()
        let firstFile = try PodcastPlacementFile(url: file)
        let probe = PlacementProbe()
        let first = coordinator.schedule(.init(itemId: "episode", file: firstFile, layers: [])) { context in await probe.run(context) }
        try Data("a new downloaded edition".utf8).write(to: file, options: .atomic)
        let secondFile = try PodcastPlacementFile(url: file)
        XCTAssertNotEqual(firstFile, secondFile)
        let second = coordinator.schedule(.init(itemId: "episode", file: secondFile, layers: [])) { context in await probe.run(context) }
        XCTAssertFalse(second.joined)
        XCTAssertTrue(first.completion.isCancelled)
        await probe.release()
        await first.completion.value
        await second.completion.value
        let writes = await probe.writes
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testTranscriptReplacesWeakWorkAndPlaybackRefreshJoinsIt() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let edition = try PodcastPlacementFile(url: file)
        let coordinator = PodcastPlacementPassCoordinator()
        let probe = PlacementProbe()
        let weak = PodcastPlacementPassCoordinator.Request(itemId: "episode", file: edition, layers: [])
        let transcript = TranscriptTimeline(segments: [.init(id: "s1", startMs: 0, endMs: 1000, text: "source words")], chapters: [])
        let first = coordinator.schedule(weak) { context in await probe.run(context) }
        let strong = coordinator.schedule(.init(itemId: "episode", file: edition, layers: [], transcript: transcript)) { context in await probe.run(context) }
        let refresh = coordinator.schedule(weak) { context in await probe.run(context) }
        XCTAssertTrue(first.completion.isCancelled)
        XCTAssertTrue(refresh.joined)
        XCTAssertEqual(refresh.id, strong.id)
        await probe.release()
        await first.completion.value
        await strong.completion.value
        await refresh.completion.value
        let transcripts = await probe.transcripts
        XCTAssertEqual(transcripts, [transcript])
    }

    @MainActor
    func testNewLayerReplacesWorkAndKeepsTheSameFilesTransientTranscript() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let edition = try PodcastPlacementFile(url: file)
        let coordinator = PodcastPlacementPassCoordinator()
        let probe = PlacementProbe()
        let transcript = TranscriptTimeline(segments: [], chapters: [], durationMs: 1000)
        let first = coordinator.schedule(.init(itemId: "episode", file: edition, layers: [], transcript: transcript)) { context in await probe.run(context) }
        let layer = ImportedCommentaryLayer(id: "new-layer", packageDigest: "digest", packageId: "packet",
            itemIdentity: .init(itemType: .podcast, title: "episode"), importedAt: Date(timeIntervalSince1970: 0))
        let second = coordinator.schedule(.init(itemId: "episode", file: edition, layers: [.init(layer: layer, records: [])])) { context in await probe.run(context) }
        XCTAssertFalse(second.joined)
        XCTAssertTrue(first.completion.isCancelled)
        await probe.release()
        await first.completion.value
        await second.completion.value
        let transcripts = await probe.transcripts
        XCTAssertEqual(transcripts, [transcript])
    }

    @MainActor
    func testSeparateItemsDoNotCancelEachOther() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let edition = try PodcastPlacementFile(url: file)
        let coordinator = PodcastPlacementPassCoordinator()
        let probe = PlacementProbe()
        let first = coordinator.schedule(.init(itemId: "first", file: edition, layers: [])) { context in await probe.run(context) }
        let second = coordinator.schedule(.init(itemId: "second", file: edition, layers: [])) { context in await probe.run(context) }
        XCTAssertFalse(first.completion.isCancelled)
        XCTAssertFalse(second.completion.isCancelled)
        await probe.release()
        await first.completion.value
        await second.completion.value
        let writes = await probe.writes
        XCTAssertEqual(writes, 2)
    }

    private func makeFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "placement-\(UUID().uuidString).bin")
        try Data("downloaded edition".utf8).write(to: file)
        return file
    }
}

private actor PlacementProbe {
    var writes = 0
    var transcripts: [TranscriptTimeline?] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ context: PodcastPlacementPassCoordinator.Context) async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
        guard !Task.isCancelled else { return }
        writes += 1
        transcripts.append(context.request.transcript)
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
