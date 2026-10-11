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

    /// A main-actor task queued before the import runs while the upgrade is away from the main actor. If the plan
    /// and the write ran inline, the import would never suspend and the task could only run after it returned.
    @MainActor
    func testTheMainActorRunsWhileTheUpgradeIsPlanned() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        let probe = MainActorProbe()
        Task { @MainActor in probe.ran = true }

        _ = try await fixture.reimportOffMain()
        let ranBeforeImportReturned = probe.ran

        XCTAssertTrue(ranBeforeImportReturned, "the upgrade held the main actor until it finished")
        XCTAssertEqual(try fixture.store.listItems().count, 1, "and the upgrade did happen")
    }

    @MainActor
    func testAPDFThatCannotMoveBecomesItsOwnEditionOffMainToo() async throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        try fixture.store.savePreparedAudioManifest(PreparedAudioManifest(
            id: "manifest-from-v1-text", itemId: fixture.v1.id, sourcePackageId: "source",
            signature: TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "digest"
            ),
            state: .preparing, plannedChunkCount: 3
        ))
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

    func testTheStoreRefusesAPlanWhenPreparedAudioWasSavedAfterItWasMade() throws {
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
        let before = try fixture.stored()

        XCTAssertThrowsError(try fixture.store.applyStructuredDocumentUpgrade(upgrade)) {
            XCTAssertEqual($0 as? StructuredDocumentUpgradeError, .changedSincePlanned)
        }

        XCTAssertEqual(try fixture.stored(), before)
    }
}

@MainActor
private final class MainActorProbe {
    var ran = false
}
