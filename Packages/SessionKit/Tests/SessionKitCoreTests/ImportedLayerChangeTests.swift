import Foundation
import SessionKit
@testable import SessionKitPersistence
import XCTest

/// #3601: a change that loads a friend's layer in order to save it again must not carry an older copy of the layer with
/// it. Each test forces the overlap on a real SQLite file: another writer holds the write lock and changes the layer
/// while the change under test is already running. A change that read first and saved later would put the old copy
/// back; one that takes the write lock before it reads sees the other change.
final class ImportedLayerChangeTests: XCTestCase {
    private var folder: URL!
    private var store: SQLiteSessionStore!
    private let date = Date(timeIntervalSince1970: 1_777_000_000)
    private let sender = String(repeating: "ab", count: 16)
    private let podcast = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights", title: "Harbour Lights")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("layer-change-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
        // The overlap relies on reads using their own connections and never waiting for the write lock; without the
        // read pool a stale read would wait too and the hook would fire before it, so the tests would pass vacuously.
        XCTAssertNotNil(store.readConnections, "reads must use pooled connections (WAL) for the overlap to prove anything")
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// The issue's case: a repair lands (the layer moves to the new item and gets its new status) while a switch is running.
    func testASwitchThatWaitsOnARepairKeepsTheRepair() throws {
        try seedLayer()
        let store = try XCTUnwrap(self.store)
        try overlap(otherWriter: { layer in
            layer.itemId = "new-item"
            layer.sourceResolutionStatus = .resolved
        }, work: {
            try ImportedLayerChange.apply(toLayerWithId: "layer", on: store) { $0.isEnabled = false }
        })

        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        XCTAssertFalse(layer.isEnabled, "the switch happened")
        XCTAssertEqual(layer.itemId, "new-item", "and the repair was not undone")
        XCTAssertEqual(layer.sourceResolutionStatus, .resolved)
    }

    func testTwoSwitchesThatOverlapBothSurvive() throws {
        try seedLayer()
        let store = try XCTUnwrap(self.store)
        try overlap(otherWriter: { $0.isMuted = true }, work: {
            try ImportedLayerChange.apply(toLayerWithId: "layer", on: store) { $0.revealMode = .guided }
        })

        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        XCTAssertTrue(layer.isMuted)
        XCTAssertEqual(layer.revealMode, .guided)
    }

    func testChangingALayerThatIsGoneChangesNothingAndSaysSo() throws {
        let applied = try ImportedLayerChange.apply(toLayerWithId: "nope", on: store) { $0.isMuted = true }
        XCTAssertFalse(applied)
        XCTAssertNil(try store.loadImportedCommentaryLayer(id: "nope"))
    }

    func testASwitchInsideAnotherTransactionRollsBackWithIt() throws {
        try seedLayer()
        struct Abandon: Error {}
        XCTAssertThrowsError(try store.withSessionTransaction {
            try ImportedLayerChange.apply(toLayerWithId: "layer", on: store) { $0.isMuted = true }
            XCTAssertTrue(try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer")).isMuted, "visible inside it")
            throw Abandon()
        })
        XCTAssertFalse(try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer")).isMuted)
    }

    func testTheSwitchWorksOnTheInMemoryRepositoryToo() throws {
        let memory = InMemorySessionRepository()
        try memory.saveImportedCommentaryLayer(layer())
        XCTAssertTrue(try ImportedLayerChange.apply(toLayerWithId: "layer", on: memory) { $0.isMuted = true })
        XCTAssertTrue(try XCTUnwrap(memory.loadImportedCommentaryLayer(id: "layer")).isMuted)
    }

    /// `importLayer`'s back-fill of the sender id on a held layer saved a copy it had read earlier in the same call.
    func testAReShareThatWaitsOnAWriterKeepsThatWritersChangeAndStillBackFills() throws {
        try seedLayer(itemId: "item-1")
        let margin = Self.margin(id: "held-1", layerId: "layer", token: token)
        try store.saveImportedCommentaryInterjection(margin)
        let store = try XCTUnwrap(self.store)
        let incoming = ImportedCommentaryLayer(
            id: "layer-U", itemId: "item-1", packageDigest: "U", packageId: "package-U", itemIdentity: podcast,
            displayLabel: "Ada", importedAt: date.addingTimeInterval(1), isEnabled: true, senderId: sender)
        let again = Self.margin(id: "local-U-1", layerId: "layer-U", token: token)
        try overlap(otherWriter: { $0.isMuted = true }, work: {
            _ = try ImportedMarginResends.importLayer(incoming, interjections: [again], repository: store)
        })

        let held = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        XCTAssertTrue(held.isMuted, "the other writer's change was not overwritten")
        XCTAssertEqual(held.senderId, sender, "and the sender id was still given to the held layer")
    }

    func testAReShareThatFailsPartwayLeavesNoBackFilledIdBehind() throws {
        try seedLayer(itemId: "item-1")
        try store.saveImportedCommentaryInterjection(Self.margin(id: "held-1", layerId: "layer", token: token))
        // A packet whose new Margin collides with a stored id: the import step at the end throws.
        let incoming = ImportedCommentaryLayer(
            id: "layer-U", itemId: "item-1", packageDigest: "U", packageId: "package-U", itemIdentity: podcast,
            displayLabel: "Ada", importedAt: date.addingTimeInterval(1), isEnabled: true, senderId: sender)
        let again = Self.margin(id: "held-1", layerId: "layer-U", token: token)
        let fresh = Self.margin(id: "held-1", layerId: "layer-U", token: Self.token("other"), transcript: "something new")
        XCTAssertThrowsError(try ImportedMarginResends.importLayer(incoming, interjections: [again, fresh], repository: store))
        XCTAssertNil(try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer")).senderId)
    }

    func testResettingPodcastPlacementsThatWaitsOnAWriterKeepsThatWritersChange() throws {
        try seedLayer(itemId: "item-1", status: .resolved, editionSHA: "old")
        let store = try XCTUnwrap(self.store)
        try overlap(otherWriter: { $0.isMuted = true }, work: {
            try store.invalidateImportedPodcastPlacements(itemId: "item-1", editionSHA256: "new")
        })

        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
        XCTAssertTrue(layer.isMuted, "the other writer's change was not overwritten")
        XCTAssertEqual(layer.sourceResolutionStatus, .pending, "and the reset still happened")
    }

    // MARK: Fixtures

    private var token: String { Self.token("friend-margin") }
    private static func token(_ margin: String) -> String { MarginShareProvenance.token(sessionId: "6F0E5D2C-1B3A-4C5D-8E7F-9A0B1C2D3E4F", interjectionId: margin)! }

    private func layer(itemId: String = "old-item", status: ImportedSourceResolutionStatus = .contextOnly, editionSHA: String? = nil) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: "layer", itemId: itemId, packageDigest: "O", packageId: "package-O", itemIdentity: podcast,
            displayLabel: "Ada", importedAt: date, sourceResolutionStatus: status, isEnabled: true, isMuted: false)
        layer.resolvedRecipientEditionSHA256 = editionSHA
        return layer
    }

    private func seedLayer(itemId: String = "old-item", status: ImportedSourceResolutionStatus = .contextOnly, editionSHA: String? = nil) throws {
        try store.saveImportedCommentaryLayer(layer(itemId: itemId, status: status, editionSHA: editionSHA))
    }

    private static func margin(id: String, layerId: String, token: String, transcript: String = "one") -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000),
            approvedTranscript: transcript, shareProvenance: token)
    }

    private final class Job: @unchecked Sendable {
        let work: () throws -> Void
        var error: Error?
        init(_ work: @escaping () throws -> Void) { self.work = work }
    }

    /// Runs `work` on a second thread while this thread holds the write lock, then changes the layer under the lock and
    /// commits. `work` therefore starts and can only take the write lock after the other change. A `work` that reads
    /// before it takes the lock has read the layer as it was; one that takes the lock first reads it as changed.
    ///
    /// The commit waits until `work` is blocked on the lock (the store says so before it waits), not for a fixed time
    /// (#4308): a change that read the layer first reads before it gets here (reads use their own connections and never
    /// wait, which `setUp` asserts), and a change that reads after taking the lock has not read yet, so only the first
    /// can save the old copy over this commit.
    private func overlap(
        otherWriter change: (inout ImportedCommentaryLayer) -> Void,
        work: @escaping () throws -> Void
    ) throws {
        let job = Job(work)
        let blocked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        store.onWaitingForWriteLock = { blocked.signal() }
        defer { store.onWaitingForWriteLock = nil }
        try store.withSessionTransaction {
            DispatchQueue.global().async {
                do { try job.work() } catch { job.error = error }
                finished.signal()
            }
            XCTAssertEqual(blocked.wait(timeout: .now() + 10), .success, "the second writer is waiting for the write lock")
            var layer = try XCTUnwrap(store.loadImportedCommentaryLayer(id: "layer"))
            change(&layer)
            try store.saveImportedCommentaryLayer(layer)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "the waiting writer finishes once the lock is free")
        XCTAssertNil(job.error)
    }
}
