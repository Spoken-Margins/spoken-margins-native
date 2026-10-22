import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// A re-imported PDF's upgrade runs off the main actor (#556). The result must be what the synchronous import
/// gives (one item, its Margins and sessions on the same words), the main actor must stay free while it runs, and a
/// Margin saved while the plan runs must not be overwritten by it.
final class StructuredDocumentUpgradeOffMainTests: XCTestCase {
    private var fixtures: [PDFReimportFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func makeFixture() throws -> PDFReimportFixture {
        let fixture = try PDFReimportFixture()
        fixtures.append(fixture)
        return fixture
    }

    private func words(_ margin: Interjection, in text: String) -> String {
        let characters = Array(text)
        return String(characters[margin.anchor.startChar..<margin.anchor.endChar])
    }

    @MainActor
    func testTheOffMainImportMovesTheItemWithItsMarginsAndPosition() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()

        let reimported = try await fixture.reimportOffMain()

        XCTAssertEqual(reimported.id, fixture.v1.id, "the same item moves; there is no second Library row")
        XCTAssertEqual(try fixture.store.listItems().count, 1)
        let stored = try fixture.stored()
        let newText = try XCTUnwrap(stored.item.text)
        XCTAssertEqual(newText, fixture.document.text)
        XCTAssertNotNil(stored.document)
        XCTAssertNotNil(stored.map)
        XCTAssertEqual(stored.margins.map { words($0, in: newText) }.sorted(), ["Methods", "morning light"])
        let session = try XCTUnwrap(stored.sessions.first)
        let position = session.position.charOffset
        XCTAssertTrue(newText.dropFirst(position).hasPrefix("Sleep improved"), "the session is still paused at the same words")
    }

    /// The synchronous import and the off-main one end in the same stored state.
    @MainActor
    func testTheOffMainImportStoresWhatTheSynchronousImportStores() async throws {
        let sync = try makeFixture()
        try sync.addReadingSession()
        _ = try sync.reimport()
        let offMain = try makeFixture()
        try offMain.addReadingSession()
        _ = try await offMain.reimportOffMain()

        XCTAssertEqual(try offMain.stored(), try sync.stored())
    }

    /// While the upgrade is planned, the main actor is free. Through the engine's seam, the plan's task queues a
    /// main-actor task that opens a semaphore, then waits on it. Off the main actor that task runs and the wait ends.
    /// If the plan held the main actor, the task could not run until the wait timed out, so a failure means only
    /// that (#2384: the old test raced an unstructured main-actor task against the import and failed spuriously).
    @MainActor
    func testTheMainActorRunsWhileTheUpgradeIsPlanned() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        let engine = fixture.engine
        let probe = PlanProbe()
        defer { engine.whileStructuredUpgradeIsPlannedForTesting = nil }
        engine.whileStructuredUpgradeIsPlannedForTesting = {
            Task { @MainActor in probe.mainActorRan.signal() }
            probe.mainActorRanDuringPlan = probe.mainActorRan.wait(timeout: .now() + 10) == .success
            probe.planRan = true
        }

        _ = try await fixture.reimportOffMain()

        XCTAssertTrue(probe.planRan, "fixture check: the re-import planned an upgrade")
        XCTAssertTrue(probe.mainActorRanDuringPlan, "the upgrade plan held the main actor: a main-actor task could not run for 10 s while it planned")
        XCTAssertEqual(try fixture.store.listItems().count, 1, "and the upgrade did happen")
    }

    @MainActor
    func testAPDFThatCannotMoveBecomesItsOwnEditionOffMainToo() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        var margin = try fixture.addMargin(id: "unmovable", sessionId: "session-reading", words: "Methods", editionHash: nil)
        margin.anchor.anchorType = .media
        try fixture.store.saveInterjection(margin)
        let before = try fixture.stored()

        let reimported = try await fixture.reimportOffMain()

        XCTAssertNotEqual(reimported.id, fixture.v1.id, "the new text is its own edition")
        XCTAssertEqual(try fixture.store.listItems().count, 2)
        XCTAssertEqual(try fixture.stored(), before, "the v1 item, Margins and positions are untouched")
    }

    @MainActor
    func testAnItemThatIsPlayingIsNotUpgradedOffMainEither() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        _ = try fixture.engine.startSession(itemId: fixture.v1.id)
        let before = try fixture.stored()

        let reimported = try await fixture.reimportOffMain()

        XCTAssertNotEqual(reimported.id, fixture.v1.id, "the new text becomes its own edition")
        XCTAssertEqual(try fixture.stored(), before)
    }

    /// The audit's path: the listener opens the item (inspecting a paused session writes nothing) while the upgrade is
    /// planned off the main actor. The write is back on the main actor with the "is it open?" check, so it sees the
    /// open item and the new text becomes its own edition; the open item keeps its text and position.
    ///
    /// The item is opened through the engine's test seam, after the plan is back and before the check. A main-actor
    /// `Task` queued before the import is not ordered against the import's continuation (the detached plan resumes at a
    /// higher priority), which made this test fail under the parallel runner (#1452).
    @MainActor
    func testOpeningTheItemDuringThePlanKeepsItOnItsOldTextAndAddsAnEdition() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        guard case .success = try fixture.plan() else { return XCTFail("fixture check: with nothing open, the upgrade moves") }
        let engine = fixture.engine
        // The closure holds the engine and the engine holds the closure; let go of it when the test ends.
        defer { engine.afterStructuredUpgradePlannedForTesting = nil }
        engine.afterStructuredUpgradePlannedForTesting = {
            XCTAssertNil(engine.currentSession, "fixture check: nothing is open until the seam opens the item")
            _ = try engine.inspectSession(sessionId: "session-reading")
        }
        let before = try fixture.stored()

        let reimported = try await fixture.reimportOffMain()

        XCTAssertEqual(engine.currentSession?.itemId, fixture.v1.id, "fixture check: the item was opened after the plan and before the write")
        XCTAssertNotEqual(reimported.id, fixture.v1.id, "the new text becomes its own edition")
        XCTAssertEqual(try fixture.store.listItems().count, 2)
        XCTAssertEqual(try fixture.stored(), before, "the open item's text, Margins and position are as the engine holds them")
        XCTAssertEqual(engine.currentItem?.text, before.item.text)
    }

    @MainActor
    func testSameTextDocumentAdoptionRetiresPreparationOnlyWhenTheHeldReaderIsPaused() async throws {
        for playing in [false, true] {
            let fixture = try makeFixture()
            try fixture.addReadingSession()
            _ = try fixture.engine.startSession(itemId: fixture.v1.id)
            if !playing { _ = try fixture.engine.pause() }
            try fixture.store.savePreparedAudioManifest(.init(
                id: "old-preparation", itemId: fixture.v1.id, sourcePackageId: "source",
                signature: .init(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v", synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"),
                state: .preparing, plannedChunkCount: 1
            ))
            try fixture.store.saveAudioPreparationJob(.init(id: "old-job", itemId: fixture.v1.id, manifestId: "old-preparation", policy: .explicit))
            let before = try fixture.stored()
            let text = try XCTUnwrap(before.item.text)
            var document = StructuredDocumentBuilder.build(lines: [.init(text: "Reference", role: .reference, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1)
            // Preserve canonical paragraph boundaries while changing their role; the reference-line builder normalizes whitespace.
            document.text = text
            document.segments[0].range = .init(start: 0, length: text.count)
            XCTAssertEqual(document.text, before.item.text)
            let imported = try await fixture.engine.importBrowserTextInBackgroundOffMain(.init(
                captureMode: .markdownFile, source: .init(url: try XCTUnwrap(fixture.v1.externalReference), title: "Paper"), text: document.text, contentFormat: .plainText
            ), structuredDocument: document)
            let after = try fixture.stored()
            XCTAssertEqual(after.item, before.item)
            XCTAssertEqual(after.map, before.map)
            XCTAssertEqual(after.sessions, before.sessions)
            XCTAssertEqual(after.margins, before.margins)
            if playing {
                XCTAssertNotEqual(imported.id, fixture.v1.id)
                XCTAssertNil(after.document)
                XCTAssertEqual(try fixture.store.loadPreparedAudioManifests(itemId: fixture.v1.id).count, 1)
                XCTAssertTrue(try fixture.store.loadAudioPreparationJobs().contains { $0.id == "old-job" })
            } else {
                XCTAssertEqual(imported.id, fixture.v1.id)
                XCTAssertEqual(after.document, document)
                XCTAssertTrue(try fixture.store.loadPreparedAudioManifests(itemId: fixture.v1.id).isEmpty)
                XCTAssertTrue(try fixture.store.loadAudioPreparationJobs().isEmpty)
            }
        }
    }

    // MARK: A Margin saved between planning and writing

    func testTheStoreRefusesAPlanWhenAMarginWasSavedAfterItWasMade() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        guard case .success(let upgrade) = try fixture.plan() else { return XCTFail("fixture should move") }
        try fixture.addMargin(id: "ij-late", sessionId: "session-reading", words: "adults", editionHash: nil)
        let before = try fixture.stored()

        XCTAssertThrowsError(try fixture.store.applyStructuredDocumentUpgrade(upgrade)) {
            XCTAssertEqual($0 as? StructuredDocumentUpgradeError, .changedSincePlanned)
        }

        XCTAssertEqual(try fixture.stored(), before, "nothing was written, so the late Margin still counts in the old text")
    }

    func testTheStoreRefusesAPlanWhenAnotherFieldOfTheItemChangedAfterItWasMade() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        guard case .success(let upgrade) = try fixture.plan() else { return XCTFail("fixture should move") }
        var renamed = try fixture.store.loadItem(id: fixture.v1.id)
        renamed.title = "Renamed while the plan ran"
        try fixture.store.saveItem(renamed)
        let before = try fixture.stored()

        XCTAssertThrowsError(try fixture.store.applyStructuredDocumentUpgrade(upgrade)) {
            XCTAssertEqual($0 as? StructuredDocumentUpgradeError, .changedSincePlanned)
        }

        XCTAssertEqual(try fixture.stored(), before, "the rename is not reverted by a plan made from the old row")
    }

    func testTheStoreRefusesAPlanWhenASessionWasStartedAfterItWasMade() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        guard case .success(let upgrade) = try fixture.plan() else { return XCTFail("fixture should move") }
        try fixture.store.saveSession(fixture.readingSession(id: "session-started-late", chapterId: nil))
        let before = try fixture.stored()

        XCTAssertThrowsError(try fixture.store.applyStructuredDocumentUpgrade(upgrade)) {
            XCTAssertEqual($0 as? StructuredDocumentUpgradeError, .changedSincePlanned)
        }

        XCTAssertEqual(try fixture.stored(), before)
    }

    func testTheStoreRetiresPreparedAudioSavedWhileThePlanWasMade() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        guard case .success(let upgrade) = try fixture.plan() else { return XCTFail("fixture should move") }
        try fixture.store.savePreparedAudioManifest(PreparedAudioManifest(
            id: "manifest-from-v1-text", itemId: fixture.v1.id, sourcePackageId: "source",
            signature: TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "digest"
            ),
            state: .preparing, plannedChunkCount: 3
        ))
        try fixture.store.applyStructuredDocumentUpgrade(upgrade)
        XCTAssertEqual(try fixture.store.loadItem(id: fixture.v1.id).text, fixture.document.text)
        XCTAssertTrue(try fixture.store.loadPreparedAudioManifests(itemId: fixture.v1.id).isEmpty)

    }
}

/// Shared by the plan's task and the test; the plan's task writes the flags before the import returns.
private final class PlanProbe: @unchecked Sendable {
    let mainActorRan = DispatchSemaphore(value: 0)
    var mainActorRanDuringPlan = false
    var planRan = false
}
