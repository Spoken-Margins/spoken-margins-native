import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The audio-preparation pass's store writes leave the main actor (#2509). Each applies in one transaction, on the job as
/// the store holds it now, and only while the preparation still belongs to its item.
final class AudioPreparationPassWritesTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pass-writes-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private let signature = TTSRenderSignature(
        engine: "supertonic", modelRevision: "r1", assetManifestHash: "a", voiceStyleHash: "v",
        synthesisParametersHash: "s", normalizationVersion: "n", chunkingVersion: "c", digest: "d")

    private func manifest(item: String = "a") -> PreparedAudioManifest {
        PreparedAudioManifest(id: "m-\(item)", itemId: item, sourcePackageId: "p", signature: signature,
                              state: .preparing, plannedChunkCount: 4)
    }

    private func job(item: String = "a", priority: Int? = nil) -> AudioPreparationJob {
        AudioPreparationJob(id: "job-\(item)", itemId: item, manifestId: "m-\(item)", policy: .explicit,
                            requestedAt: Date(timeIntervalSince1970: 10), userPriority: priority, nextChunkIndex: 1)
    }

    private func seed(_ store: SQLiteSessionStore, item: String = "a") throws {
        try store.saveItem(Item(id: item, title: "T", mediaType: "text", text: "Words to read aloud.", externalReference: nil, status: "ready"))
        try store.savePreparedAudioManifest(manifest(item: item))
        try store.saveAudioPreparationJob(job(item: item))
    }

    /// A priority the listener sets while the chunk renders must survive the pass recording that chunk.
    func testRecordedChunkAppliesToTheJobAsTheStoreHoldsItNow() throws {
        let store = try makeStore()
        try seed(store)
        let staleCopy = job() // what the pass held before it started rendering
        try store.saveAudioPreparationJob(job(priority: 3)) // the listener pinned it meanwhile

        let decision = try AudioPreparationPassWrites.recordChunk(
            in: manifest(), jobId: "job-a", fallback: staleCopy, decide: { fresh in
                var next = fresh
                next.nextChunkIndex = 2
                return .init(change: .save(next), needsAssembly: false, note: "saved")
            }, store: store)

        XCTAssertEqual(decision?.note, "saved")
        let saved = try XCTUnwrap(store.loadAudioPreparationJob(id: "job-a"))
        XCTAssertEqual(saved.nextChunkIndex, 2)
        XCTAssertEqual(saved.userPriority, 3, "the pin is kept")
    }

    func testRecordedChunkCanDeleteTheFinishedJob() throws {
        let store = try makeStore()
        try seed(store)
        let decision = try AudioPreparationPassWrites.recordChunk(
            in: manifest(), jobId: "job-a", fallback: job(),
            decide: { _ in .init(change: .delete(id: "job-a"), needsAssembly: true) }, store: store)
        XCTAssertEqual(decision?.needsAssembly, true)
        XCTAssertNil(try store.loadAudioPreparationJob(id: "job-a"))
    }

    func testNothingIsWrittenOnceTheItemIsTrashed() throws {
        let store = try makeStore()
        try seed(store)
        try store.moveItemToTrash(id: "a")
        var decided = false
        let recorded = try AudioPreparationPassWrites.recordChunk(
            in: manifest(), jobId: "job-a", fallback: job(), decide: { _ in
                .init(change: .delete(id: "job-a"), needsAssembly: false)
            }, store: store)
        decided = recorded != nil
        XCTAssertFalse(decided)
        XCTAssertNotNil(try store.loadAudioPreparationJob(id: "job-a"), "the stale write did not delete the job")
        XCTAssertFalse(try AudioPreparationPassWrites.retireManifest(manifest(), discardingJobId: "job-a", in: store))
        XCTAssertNotNil(try store.loadAudioPreparationJob(id: "job-a"))
    }

    func testRetiringAManifestSavesItAndDropsItsJobTogether() throws {
        let store = try makeStore()
        try seed(store)
        var retired = manifest()
        retired.state = .needsRepreparation
        XCTAssertTrue(try AudioPreparationPassWrites.retireManifest(retired, discardingJobId: "job-a", in: store))
        XCTAssertEqual(try store.loadPreparedAudioManifest(id: "m-a")?.state, .needsRepreparation)
        XCTAssertNil(try store.loadAudioPreparationJob(id: "job-a"))
    }

    func testFailureMarkChangesOnlyTheCodeAndDoesNotBringBackAGoneJob() throws {
        let store = try makeStore()
        try seed(store)
        try store.saveAudioPreparationJob(job(priority: 5))
        try AudioPreparationPassWrites.markFailure(jobId: "job-a", manifestId: "m-a", code: "boom", in: store)
        let marked = try XCTUnwrap(store.loadAudioPreparationJob(id: "job-a"))
        XCTAssertEqual(marked.lastFailureCode, "boom")
        XCTAssertEqual(marked.userPriority, 5)
        XCTAssertEqual(marked.nextChunkIndex, 1)

        try store.deleteAudioPreparationJob(id: "job-a") // the listener skipped the item meanwhile
        try AudioPreparationPassWrites.markFailure(jobId: "job-a", manifestId: "m-a", code: "late", in: store)
        XCTAssertNil(try store.loadAudioPreparationJob(id: "job-a"))
    }

    func testExpiryMarksOnlyTheRemainingExplicitRequests() throws {
        let store = try makeStore()
        try seed(store)
        try store.saveItem(Item(id: "b", title: "B", mediaType: "text", text: "More words.", externalReference: nil, status: "ready"))
        try store.saveAudioPreparationJob(AudioPreparationJob(
            id: "job-b", itemId: "b", manifestId: "m-b", policy: .explicit, requestedAt: Date(timeIntervalSince1970: 20)))
        let requests: Set<OfflinePreparationRun.RequestKey> = [.init(jobId: "job-a", requestedAt: Date(timeIntervalSince1970: 10))]
        XCTAssertEqual(try AudioPreparationQueueEdits.markInterrupted(requests: requests, in: store), 1)
        XCTAssertEqual(try store.loadAudioPreparationJob(id: "job-a")?.lastFailureCode, OfflinePreparationRecovery.waitingForSystem)
        XCTAssertNil(try store.loadAudioPreparationJob(id: "job-b")?.lastFailureCode)
    }

    /// A chunk recorded while the listener pins the job: both land, in the order asked, because both go through the
    /// queue's ordered line. Neither loses the other's change.
    func testRecordsAndQueueEditsInTheSameLineKeepBothChanges() async throws {
        let store = try makeStore()
        try seed(store)
        let reader = StoreReader(store)
        let (manifest, staleJob) = (manifest(), job())
        let record = Task {
            try await reader.readInOrder(AudioPreparationQueueEdits.orderKey) { store in
                try AudioPreparationPassWrites.recordChunk(
                    in: manifest, jobId: "job-a", fallback: staleJob, decide: { fresh in
                        var next = fresh
                        next.nextChunkIndex = 2
                        return .init(change: .save(next), needsAssembly: false)
                    }, store: store)
            }
        }
        let pin = Task {
            try await reader.readInOrder(AudioPreparationQueueEdits.orderKey) { store in
                try AudioPreparationQueueEdits.prioritize(id: "job-a", in: store)
            }
        }
        _ = try await record.value
        _ = try await pin.value
        let saved = try XCTUnwrap(store.loadAudioPreparationJob(id: "job-a"))
        XCTAssertEqual(saved.nextChunkIndex, 2)
        XCTAssertNotNil(saved.userPriority)
    }

    /// A write issued from a cancelled task still lands: the expiry path runs exactly when the pass is cancelled.
    func testFailureMarkLandsEvenWhenItsCallerIsCancelled() async throws {
        let store = try makeStore()
        try seed(store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) { store in
                try AudioPreparationPassWrites.markFailure(jobId: "job-a", manifestId: "m-a", code: "expired", in: store)
            }
        }
        try await task.value
        XCTAssertEqual(try store.loadAudioPreparationJob(id: "job-a")?.lastFailureCode, "expired")
    }
}
