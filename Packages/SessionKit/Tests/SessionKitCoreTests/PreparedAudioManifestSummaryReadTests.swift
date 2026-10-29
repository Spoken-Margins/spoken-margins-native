import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2506: every Library reload decoded every prepared-audio manifest with its whole chunk list, 1.1 MB for the
/// Library fixture and as slow as reading all the item summaries, to learn each manifest's state, plan and how many
/// of its first chunks exist. The Library now reads manifest summaries that SQLite cuts the chunks out of.
/// Real SQLite on a real file; a summary must equal the summary of the whole manifest.
final class PreparedAudioManifestSummaryReadTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "manifest-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var signature: TTSRenderSignature {
        TTSRenderSignature(engine: "kitten", modelRevision: "r1", assetManifestHash: "a", voiceStyleHash: "v",
                           synthesisParametersHash: "s", normalizationVersion: "n", chunkingVersion: "c", digest: "d")
    }

    private func chunk(_ item: String, _ index: Int) -> PreparedAudioChunk {
        let range = SourceLocator(documentId: item, segmentId: "p\(index)", utf8Start: index * 100, utf8End: (index + 1) * 100)
        return PreparedAudioChunk(
            id: "\(item)-chunk-\(index)", index: index, sourceRange: range, relativePath: "Prepared/\(item)/chunk-\(index).m4a",
            byteCount: 1_000, checksumSHA256: "x", durationMs: 2_000, committedAt: epoch, engine: index == 1 ? "ios" : nil)
    }

    private func manifest(
        _ item: String, state: PreparedAudioState = .readyOffline, planned: Int = 6, chunks chunkIndexes: [Int]? = nil,
        artifact: Bool = true, failure: String? = nil, updatedAt: Double = 0
    ) -> PreparedAudioManifest {
        let indexes: [Int] = chunkIndexes ?? Array(0..<planned)
        let chunks: [PreparedAudioChunk] = indexes.map { chunk(item, $0) }
        let made: PreparedAudioArtifact? = artifact
            ? PreparedAudioArtifact(relativePath: "Prepared/\(item).m4a", byteCount: 9, checksumSHA256: "y", durationMs: 12_000)
            : nil
        return PreparedAudioManifest(
            id: "manifest-\(item)", itemId: item, sourcePackageId: "source-\(item)", signature: signature, state: state,
            plannedChunkCount: planned, chunks: chunks, artifact: made, failureCode: failure, createdAt: epoch,
            updatedAt: epoch.addingTimeInterval(updatedAt), articleIdentity: "identity-\(item)")
    }

    /// Neighbouring manifests: finished, partway, no chunk yet, a failure, no artifact, chunks stored out of order.
    private func table() -> [PreparedAudioManifest] {
        var shuffled = manifest("shuffled", state: .preparing, planned: 5, updatedAt: 5)
        shuffled.chunks.reverse()
        return [
            manifest("done", updatedAt: 1),
            manifest("partway", state: .preparing, planned: 9, chunks: [0, 1, 2], artifact: false, updatedAt: 2),
            manifest("fresh", state: .notPrepared, planned: 4, chunks: [], artifact: false, updatedAt: 3),
            manifest("failed", state: .failed, planned: 4, chunks: [0], artifact: false, failure: "synth_failed", updatedAt: 4),
            shuffled,
            manifest("gap", state: .pausedForThermal, planned: 8, chunks: [0, 3, 4], artifact: false, updatedAt: 6),
        ]
    }

    func testSummariesEqualTheSummariesOfTheWholeManifestsInTheSameOrder() throws {
        let store = try SQLiteSessionStore(path: path)
        for manifest in table() { try store.savePreparedAudioManifest(manifest) }
        let summaries = try store.loadPreparedAudioManifestSummaries()
        let whole = try store.loadPreparedAudioManifests()
        XCTAssertEqual(summaries.count, table().count)
        XCTAssertEqual(summaries, whole.map(\.summary))
        let partway = try XCTUnwrap(summaries.first { $0.itemId == "partway" })
        XCTAssertEqual(partway.committedChunkCount, 3)
        XCTAssertEqual(partway.committedChunkCount(before: 2), 2)
        XCTAssertEqual(try XCTUnwrap(summaries.first { $0.itemId == "gap" }).committedChunkCount(before: 2), 1)
        XCTAssertEqual(try XCTUnwrap(summaries.first { $0.itemId == "failed" }).failureCode, "synth_failed")
        XCTAssertEqual(try XCTUnwrap(summaries.first { $0.itemId == "done" }).artifact?.durationMs, 12_000)
    }

    func testTheLibraryRowsEqualTheRowsOfTheWholeManifests() throws {
        let store = try SQLiteSessionStore(path: path)
        var items: [Item] = []
        for manifest in table() {
            let item = Item(id: manifest.itemId, title: "Title \(manifest.itemId)", mediaType: "text", text: "Words to read aloud.",
                            externalReference: "https://example.com/\(manifest.itemId)", status: "ready", externalReferenceType: "article",
                            createdAt: epoch)
            items.append(item)
            try store.saveItem(item)
            try store.savePreparedAudioManifest(manifest)
        }
        let context = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true, renderSignature: signature)
        let fromSummaries = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: context)
        let fromWhole = LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(
                items: items, sessions: [], manifests: try store.loadPreparedAudioManifests().map(\.summary),
                jobs: [], downloads: []),
            context: context)
        XCTAssertEqual(fromSummaries.map(\.id).sorted(), fromWhole.map(\.id).sorted())
        for row in fromSummaries {
            let other = try XCTUnwrap(fromWhole.first { $0.id == row.id })
            XCTAssertEqual(row.startupAudioState, other.startupAudioState, row.id)
            XCTAssertEqual(row.startupAudioCompletedChunkCount, other.startupAudioCompletedChunkCount, row.id)
            XCTAssertEqual(row.offlineState, other.offlineState, row.id)
        }
        XCTAssertEqual(try XCTUnwrap(fromSummaries.first { $0.id == "partway" }).startupAudioCompletedChunkCount, 2)
    }

    func testAManifestThatCannotBeCutOrDecodedIsSetAsideAndTheRestStillRead() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.savePreparedAudioManifest(manifest("good"))
        try StoreRawSQL.execute(
            "INSERT INTO records(kind,id,session_id,item_id,payload) VALUES('prepared_audio_manifest','broken',NULL,'broken',?);",
            bindings: [#"{"id":"broken","itemId":"broken","state":"not_a_state","chunks":[]}"#], at: path)
        let summaries = try store.loadPreparedAudioManifestSummaries()
        XCTAssertEqual(summaries.map(\.itemId), ["good"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1, "set aside as the full read would")
    }

    func testAManifestWhoseChunkListIsNotAnArrayFallsBackToTheFullRead() throws {
        let store = try SQLiteSessionStore(path: path)
        try store.savePreparedAudioManifest(manifest("good"))
        try StoreRawSQL.execute(
            "INSERT INTO records(kind,id,session_id,item_id,payload) VALUES('prepared_audio_manifest','odd',NULL,'odd',?);",
            bindings: [#"{"id":"odd","itemId":"odd","chunks":"none"}"#], at: path)
        XCTAssertEqual(try store.loadPreparedAudioManifestSummaries().map(\.itemId), ["good"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
    }

    func testTheSummaryReadCopiesAFractionOfTheBytesOfTheWholeRead() throws {
        let meter = StoreReadMeter()
        let store = try SQLiteSessionStore(path: path, readMeter: meter)
        for index in 0..<40 {
            try store.savePreparedAudioManifest(manifest("item-\(index)", planned: 120, updatedAt: Double(index)))
        }
        meter.reset()
        XCTAssertEqual(try store.loadPreparedAudioManifestSummaries().count, 40)
        let summaryRead = meter.totals(for: "loadPreparedAudioManifestSummaries()")
        XCTAssertEqual(try store.loadPreparedAudioManifests().count, 40)
        let wholeRead = meter.totals(for: "loadPreparedAudioManifests()")
        XCTAssertEqual(summaryRead.rows, 40)
        XCTAssertGreaterThan(wholeRead.bytes, 40 * 20_000, "each fixture manifest carries a real chunk list")
        XCTAssertLessThan(summaryRead.bytes, wholeRead.bytes / 10, "the chunks are cut out in SQLite, not copied and dropped (#2506)")
        XCTAssertEqual(meter.totals(for: "loadPreparedAudioManifests()").calls, 1, "the summary read did not fall back")
    }

    func testTheLibrarySnapshotNoLongerReadsTheWholeManifests() throws {
        let meter = StoreReadMeter()
        let store = try SQLiteSessionStore(path: path, readMeter: meter)
        for manifest in table() { try store.savePreparedAudioManifest(manifest) }
        meter.reset()
        _ = try LibraryReadSnapshot.read(store: store)
        XCTAssertEqual(meter.totals(for: "loadPreparedAudioManifests()").calls, 0)
        XCTAssertEqual(meter.totals(for: "loadPreparedAudioManifestSummaries()").calls, 1)
    }
}
