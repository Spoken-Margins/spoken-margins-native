import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// A placement pass copies a layer when it starts and saves its result minutes later. What the listener
/// changed meanwhile must survive, and a layer they deleted must stay deleted (#915). Real SQLite file.
final class PlacementPassSaveTests: XCTestCase {
    private var path = ""
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-placement-\(UUID().uuidString).sqlite").path
        store = try SQLiteSessionStore(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func testTheListenersChoicesMadeDuringThePassSurviveAndThePassResultIsSaved() throws {
        let original = layer("layer-a", status: .pending)
        try store.saveImportedCommentaryLayer(original)

        // The pass starts from this copy ...
        var passCopy = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))
        // ... the listener turns the layer off and changes how it plays ...
        var edited = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))
        edited.isEnabled = false
        edited.revealMode = .guided
        edited.isMuted = true
        try store.saveImportedCommentaryLayer(edited)
        // ... and the pass finishes.
        passCopy.sourceResolutionStatus = .resolved
        passCopy.resolvedRecipientEditionSHA256 = "edition-digest"
        passCopy.sharedMapRefusalReason = "no matching scene"
        XCTAssertTrue(try store.savePlacementResult(of: passCopy))

        let saved = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.revealMode, .guided)
        XCTAssertTrue(saved.isMuted)
        XCTAssertEqual(saved.sourceResolutionStatus, .resolved)
        XCTAssertEqual(saved.resolvedRecipientEditionSHA256, "edition-digest")
        XCTAssertEqual(saved.sharedMapRefusalReason, "no matching scene")
    }

    func testALayerDeletedDuringThePassStaysDeleted() throws {
        let original = layer("layer-b", status: .pending)
        try store.saveImportedCommentaryLayer(original)
        var passCopy = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))

        var deleted = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))
        deleted.deletedAt = Date(timeIntervalSince1970: 1_777_000_100)
        deleted.isEnabled = false
        try store.saveImportedCommentaryLayer(deleted)

        passCopy.sourceResolutionStatus = .resolved
        passCopy.resolvedRecipientEditionSHA256 = "edition-digest"
        XCTAssertFalse(try store.savePlacementResult(of: passCopy))

        let saved = try XCTUnwrap(store.loadImportedCommentaryLayer(id: original.id))
        XCTAssertEqual(saved.deletedAt, Date(timeIntervalSince1970: 1_777_000_100))
        XCTAssertFalse(saved.isEnabled)
        XCTAssertEqual(saved.sourceResolutionStatus, .pending)
        XCTAssertNil(saved.resolvedRecipientEditionSHA256)
    }

    func testALayerThatNoLongerExistsIsNotCreatedByThePass() throws {
        let ghost = layer("layer-never-saved", status: .resolved)
        XCTAssertFalse(try store.savePlacementResult(of: ghost))
        XCTAssertNil(try store.loadImportedCommentaryLayer(id: ghost.id))
        XCTAssertTrue(try store.loadImportedCommentaryLayers().isEmpty)
    }

    func testTwoLayersAreSavedIndependently() throws {
        let kept = layer("layer-kept", status: .pending)
        let removed = layer("layer-removed", status: .pending)
        try store.saveImportedCommentaryLayer(kept)
        try store.saveImportedCommentaryLayer(removed)
        var passKept = kept, passRemoved = removed
        passKept.sourceResolutionStatus = .resolved
        passRemoved.sourceResolutionStatus = .resolved

        var gone = removed
        gone.deletedAt = Date(timeIntervalSince1970: 1_777_000_100)
        gone.isEnabled = false
        try store.saveImportedCommentaryLayer(gone)

        XCTAssertTrue(try store.savePlacementResult(of: passKept))
        XCTAssertFalse(try store.savePlacementResult(of: passRemoved))
        XCTAssertEqual(try store.loadImportedCommentaryLayer(id: kept.id)?.sourceResolutionStatus, .resolved)
        XCTAssertNotNil(try store.loadImportedCommentaryLayer(id: removed.id)?.deletedAt)
    }

    func testALayerIsLiveOnlyWhileItIsStoredAndNotDeleted() throws {
        let original = layer("layer-live", status: .pending)
        XCTAssertFalse(try store.isLiveImportedCommentaryLayer(id: original.id))
        try store.saveImportedCommentaryLayer(original)
        XCTAssertTrue(try store.isLiveImportedCommentaryLayer(id: original.id))
        var deleted = original
        deleted.deletedAt = Date(timeIntervalSince1970: 1_777_000_100)
        try store.saveImportedCommentaryLayer(deleted)
        XCTAssertFalse(try store.isLiveImportedCommentaryLayer(id: original.id))
    }

    private func layer(_ id: String, status: ImportedSourceResolutionStatus) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
                                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                displayLabel: "Ada", importedAt: Date(timeIntervalSince1970: 1_777_000_000),
                                sourceResolutionStatus: status, isEnabled: true)
    }
}
