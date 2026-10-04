import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class PDFReimportAuditTests: XCTestCase {
    private var document: StructuredDocument {
        StructuredDocumentBuilder.build(lines: [
            .init(text: "Paper", role: .title, pageIndex: 0),
            .init(text: "New header", role: .pageHeader, pageIndex: 0),
            .init(text: "We measured sleep in adults.", role: .body, pageIndex: 0)
        ], engine: "pdfkit_baseline", version: 2, pageCount: 1)
    }
    private func handoff(_ text: String) -> BrowserTextHandoff {
        .init(captureMode: .markdownFile, source: .init(url: "shared-file://share-sheet/Paper.pdf", title: "Paper"), text: text, contentFormat: .plainText)
    }
    private func engine(_ store: any SessionRepository) -> SessionEngine {
        .init(profile: .init(id: "pdf", displayName: "PDF", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
    }
    private func manifest(_ item: Item) -> PreparedAudioManifest {
        .init(id: "prepared", itemId: item.id, sourcePackageId: "source",
              signature: .init(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v", synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
              state: .preparing, plannedChunkCount: 1)
    }

    func testStaleEnqueueAfterUpgradeCreatesNoPreparationRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
        let upgraded = try engine.importBrowserTextInBackground(handoff(document.text), structuredDocument: document)
        XCTAssertEqual(upgraded.id, old.id)
        func enqueue(_ text: String) throws {
            try PreparedAudioEnqueue.withValidatedSource(itemId: old.id, sourceText: text, repository: store) {
                let manifest = manifest(old)
                try store.savePreparedAudioManifest(manifest)
                try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: manifest.id, policy: .whileCharging))
            }
        }
        XCTAssertThrowsError(try enqueue(old.text!))
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
        XCTAssertThrowsError(try enqueue(upgraded.text!))
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }

    func testEligibleEnqueueRollsBackPartialRecordsOnError() throws {
        enum Failure: Error { case stopped }
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let item = try engine(store).importBrowserTextInBackground(handoff("We measured sleep in adults."))
        XCTAssertThrowsError(try PreparedAudioEnqueue.withValidatedSource(itemId: item.id, sourceText: item.text!, repository: store) {
            try store.savePreparedAudioManifest(manifest(item))
            throw Failure.stopped
        })
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: item.id).isEmpty)
        try PreparedAudioEnqueue.withValidatedSource(itemId: item.id, sourceText: item.text!, repository: store) {
            try store.savePreparedAudioManifest(manifest(item))
        }
        XCTAssertEqual(try store.loadPreparedAudioManifests(itemId: item.id).count, 1)
    }

    func testJobConfigurationPreservesStartupThenPromotesCompletedHorizon() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let item = try engine(store).importBrowserTextInBackground(handoff("We measured sleep in adults."))
        var prepared = manifest(item)
        try store.savePreparedAudioManifest(prepared)
        let order = Date(timeIntervalSince1970: 123)
        let startup = try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: item.text!, repository: store, request: .startup(maximumChunkCount: 1, requestedAt: order))
        XCTAssertEqual(startup?.policy, .demandWindow)
        XCTAssertEqual(startup?.maximumChunkCount, 1)
        XCTAssertEqual(startup?.requestedAt, order)
        let automatic = try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: item.text!, repository: store, request: .automatic(requestedAt: order))
        XCTAssertEqual(automatic, startup, "Automatic passes must preserve the startup horizon")
        prepared.chunks = [PreparedAudioChunk(id: "chunk", index: 0, sourceRange: SourceLocator(documentId: "source", segmentId: "s", utf8Start: 0, utf8End: 5), relativePath: "chunk.wav", byteCount: 1, checksumSHA256: "c", durationMs: 100)]
        try store.savePreparedAudioManifest(prepared)
        let promoted = try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: item.text!, repository: store, request: .automatic(requestedAt: order))
        XCTAssertEqual(promoted?.policy, .whileCharging)
        XCTAssertNil(promoted?.maximumChunkCount)
        let explicit = try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: item.text!, repository: store, request: .explicit)
        XCTAssertEqual(explicit?.policy, .explicit)
        XCTAssertNil(explicit?.maximumChunkCount)
        prepared.state = .readyOffline
        try store.savePreparedAudioManifest(prepared)
        try store.deleteAudioPreparationJob(id: explicit!.id)
        XCTAssertNil(try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: item.text!, repository: store, request: .explicit))
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }

    func testJobPolicyUpdateCannotRecreatePreparationRetiredAfterBegin() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
        let prepared = manifest(old)
        try store.savePreparedAudioManifest(prepared)
        try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: prepared.id, policy: .demandWindow))
        let upgraded = try engine.importBrowserTextInBackground(handoff(document.text), structuredDocument: document)
        XCTAssertEqual(upgraded.id, old.id)
        for request in [PreparedAudioEnqueue.Request.startup(maximumChunkCount: 1, requestedAt: nil), .automatic(requestedAt: nil), .explicit] {
            XCTAssertThrowsError(try PreparedAudioEnqueue.configureJob(manifest: prepared, sourceText: old.text!, repository: store, request: request))
        }
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }

    func testProgressOrRetryCannotRestoreARetiredManifestAndJob() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
        let prepared = manifest(old)
        try store.savePreparedAudioManifest(prepared)
        let initial = try PreparedAudioEnqueue.withCurrentManifest(prepared, repository: store) { candidate, _ in
            try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: candidate.id, policy: .explicit))
            return true
        }
        XCTAssertEqual(initial, true)
        let upgraded = try engine.importBrowserTextInBackground(handoff(document.text), structuredDocument: document)
        XCTAssertEqual(upgraded.id, old.id)
        let saved = try PreparedAudioEnqueue.withCurrentManifest(prepared, repository: store) { candidate, _ in
            try store.savePreparedAudioManifest(candidate)
            try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: candidate.id, policy: .explicit))
            return true
        }
        XCTAssertNil(saved)
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }

    func testUpgradeRetiresPreparationEnqueuedWhilePlanning() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
        let result = try StructuredDocumentUpgrader.plan(existing: store.loadItem(id: old.id), document: document, listeningMap: nil, repository: store)
        guard case .success(let plan) = result else { return XCTFail("Fixture must upgrade") }
        try PreparedAudioEnqueue.withValidatedSource(itemId: old.id, sourceText: old.text!, repository: store) {
            let prepared = manifest(old)
            try store.savePreparedAudioManifest(prepared)
            try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: prepared.id, policy: .whileCharging))
        }
        try store.applyStructuredDocumentUpgrade(plan)
        XCTAssertEqual(try store.listItems().count, 1)
        XCTAssertEqual(try store.loadItem(id: old.id).text, document.text)
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }

    func testUpgradeRejectsAPlanAfterItsInputsChange() throws {
        for change in ["item", "session", "newSession", "document"] {
            let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
            defer { try? FileManager.default.removeItem(at: path) }
            let store = try SQLiteSessionStore(path: path.path)
            let old = try engine(store).importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
            let session = Session(id: "session", itemId: old.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: old.id, position: .init(charOffset: 6), completionPercent: 10, playbackRate: 1)
            try store.saveSession(session)
            let result = try StructuredDocumentUpgrader.plan(existing: try store.loadItem(id: old.id), document: document, listeningMap: nil, repository: store)
            guard case .success(let plan) = result else { return XCTFail("Fixture must upgrade") }
            switch change {
            case "item":
                var edited = old; edited.title = "Renamed during planning"; try store.saveItem(edited)
            case "session":
                var moved = session; moved.position.charOffset += 1; try store.saveSession(moved)
            case "newSession":
                var added = session; added.id = "new-session"; try store.saveSession(added)
            case "document":
                try store.saveStructuredDocument(document, itemId: old.id)
            default:
                XCTFail("Unknown fixture change")
            }
            let itemBefore = try store.loadItem(id: old.id)
            let sessionsBefore = try store.loadSessions(itemId: old.id)
            let preparationBefore = try store.loadPreparedAudioManifests(itemId: old.id)
            let documentBefore = try store.loadStructuredDocument(itemId: old.id)
            XCTAssertThrowsError(try store.applyStructuredDocumentUpgrade(plan), change)
            XCTAssertEqual(try store.loadItem(id: old.id), itemBefore, change)
            XCTAssertEqual(try store.loadSessions(itemId: old.id), sessionsBefore, change)
            XCTAssertEqual(try store.loadPreparedAudioManifests(itemId: old.id), preparationBefore, change)
            XCTAssertEqual(try store.loadStructuredDocument(itemId: old.id), documentBefore, change)
        }
    }

    @MainActor
    func testAwaitedUpgradeReadsPlansAndPersistsOffMainThread() async throws {
        let store = ThreadCheckingRepository()
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff("Paper\nWe measured sleep in adults."))
        let session = Session(id: "session", itemId: old.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: old.id, position: .init(charOffset: 6), completionPercent: 10, playbackRate: 1)
        try store.saveSession(session)
        store.sawWrite = false
        store.checkThreads = true
        let item = try await engine.importBrowserTextInBackgroundAsync(handoff(document.text), structuredDocument: document)
        XCTAssertEqual(item.id, old.id)
        XCTAssertTrue(store.sawWrite, "Observe the actual upgrade writes as well as planning reads")
        XCTAssertFalse(store.sawMainThread, "Upgrade reads, planning inputs and persistence must leave the UI thread")
        store.checkThreads = false
        XCTAssertEqual(try store.loadStructuredDocument(itemId: item.id), document)
        XCTAssertEqual(try store.loadSession(id: session.id)?.position.charOffset, document.text.range(of: "We measured").map { document.text.distance(from: document.text.startIndex, to: $0.lowerBound) })
    }

    func testIdenticalTextReimportRetiresPlainTextPreparation() throws {
        // #344 audit 4 on 921487b: adopting a document without a text change kept the
        // plain text's preparation, which can no longer commit, so its job ran forever.
        let path = FileManager.default.temporaryDirectory.appending(path: "audit-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = engine(store)
        let old = try engine.importBrowserTextInBackground(handoff(document.text))
        XCTAssertEqual(old.text, document.text, "exercise an identical-text re-import")
        let prepared = manifest(old)
        try store.savePreparedAudioManifest(prepared)
        try store.saveAudioPreparationJob(.init(id: "job", itemId: old.id, manifestId: prepared.id, policy: .whileCharging))
        let reimported = try engine.importBrowserTextInBackground(handoff(document.text), structuredDocument: document)
        XCTAssertEqual(reimported.id, old.id)
        XCTAssertEqual(try store.loadStructuredDocument(itemId: old.id), document)
        XCTAssertTrue(try store.loadPreparedAudioManifests(itemId: old.id).isEmpty)
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
    }
}

private final class ThreadCheckingRepository: InMemorySessionRepository, @unchecked Sendable {
    override var items: [String: Item] { didSet { sawWrite = true; observe() } }
    override var sessions: [String: Session] { didSet { sawWrite = true; observe() } }
    override var structuredDocuments: [String: [Int: StructuredDocument]] { didSet { sawWrite = true; observe() } }
    var sawWrite = false
    var checkThreads = false
    var sawMainThread = false
    private func observe() { if checkThreads && Thread.isMainThread { sawMainThread = true } }
    override func loadItem(id: String) throws -> Item { observe(); return try super.loadItem(id: id) }
    override func saveItem(_ item: Item) throws { observe(); try super.saveItem(item) }
    override func loadInterjections(sessionId: String) throws -> [Interjection] { observe(); return try super.loadInterjections(sessionId: sessionId) }
    override func saveSession(_ session: Session) throws { observe(); try super.saveSession(session) }
}
