import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #4173 PR 1: one setter for the sharing star, whatever screen it comes from. The star is the way Share knows which of the
/// listener's Margins to start with, so a star must reach Share at once, a quick second tap must undo the first, and a
/// Margin the store doesn't have must say so once and change nothing.
@MainActor
final class ShareStarSetterTests: XCTestCase {
    private struct Fixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let itemId: String
        let currentSessionId: String
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-star-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        let itemId = model.selectedItem.id
        model.startItem(id: itemId)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        return Fixture(model: model, store: try SQLiteSessionStore(path: url.path), itemId: itemId, currentSessionId: sessionId, root: root)
    }

    private func margin(id: String, itemId: String, sessionId: String) -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "Keep this one.", cleanedTranscript: nil, displayText: nil, status: "active"
        )
    }

    /// `burst`: the flip is made on the saved Margin inside the store's write, so a screen that still holds the old value
    /// cannot make two taps both say "on".
    func testQuickTapsFlipTheStarEachTimeEvenFromAStaleMargin() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stale = margin(id: "m-burst", itemId: fixture.itemId, sessionId: fixture.currentSessionId)
        try fixture.store.saveInterjection(stale)
        fixture.model.openItem(id: fixture.itemId)

        func saved() throws -> Bool? { try fixture.store.loadInterjections(sessionId: fixture.currentSessionId).first { $0.id == "m-burst" }?.isStarredForSharing }
        fixture.model.toggleStarredForSharing(stale, place: .detail)
        XCTAssertEqual(try saved(), true)
        fixture.model.toggleStarredForSharing(stale, place: .detail) // the same unstarred copy, tapped again
        XCTAssertNotEqual(try saved(), true, "two taps leave it off")
        fixture.model.toggleStarredForSharing(stale, place: .detail)
        XCTAssertEqual(try saved(), true, "three leave it on")
    }

    /// The star shows on the selected item at once, so Share, which starts from the stars, never opens without a Margin the
    /// listener starred a moment ago. A Margin of another session of the item is not on the selected item (the detail holds the
    /// active session's Margins): its star is saved and nothing is put on the screen for it.
    func testAStarShowsOnTheSelectedItemAtOnceAndAnotherSessionsMarginIsOnlySaved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var earlier = try XCTUnwrap(fixture.store.loadSession(id: fixture.currentSessionId))
        earlier.id = "earlier-session"
        try fixture.store.saveSession(earlier)
        let older = margin(id: "m-older", itemId: fixture.itemId, sessionId: "earlier-session")
        let current = margin(id: "m-current", itemId: fixture.itemId, sessionId: fixture.currentSessionId)
        let other = margin(id: "m-other", itemId: fixture.itemId, sessionId: fixture.currentSessionId)
        try fixture.store.saveInterjection(older)
        try fixture.store.saveInterjection(current)
        try fixture.store.saveInterjection(other)
        fixture.model.openItem(id: fixture.itemId)
        let shown = try XCTUnwrap(fixture.model.selectedItem.interjections.first { $0.id == "m-current" })
        let before = fixture.model.selectedItem.interjections.map(\.id)

        fixture.model.setStarredForSharing(shown, starred: true, place: .marginsTab)

        XCTAssertEqual(fixture.model.selectedItem.interjections.first { $0.id == "m-current" }?.isStarredForSharing, true, "shown before any reload")
        fixture.model.prepareShareInterjections()
        XCTAssertEqual(fixture.model.sharingState.draftFilter, .starred)
        XCTAssertEqual(fixture.model.sharingState.drafts.filter(\.isIncluded).map(\.id), ["m-current"])

        fixture.model.setStarredForSharing(older, starred: true, place: .marginsTab)
        XCTAssertEqual(try fixture.store.loadInterjections(sessionId: "earlier-session").first?.isStarredForSharing, true, "saved")
        XCTAssertEqual(fixture.model.selectedItem.interjections.map(\.id), before, "nothing was added to the screen for another session's Margin")
    }

    /// `store`: a Margin the store doesn't have is reported once and nothing on screen changes.
    func testAMarginTheStoreDoesNotHaveReportsTheFailureAndChangesNothing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let present = margin(id: "m-present", itemId: fixture.itemId, sessionId: fixture.currentSessionId)
        try fixture.store.saveInterjection(present)
        fixture.model.openItem(id: fixture.itemId)
        let before = fixture.model.selectedItem.interjections
        let missing = margin(id: "m-missing", itemId: fixture.itemId, sessionId: fixture.currentSessionId)
        XCTAssertNil(fixture.model.lastError)

        fixture.model.toggleStarredForSharing(missing, place: .detail)

        XCTAssertEqual(fixture.model.lastError?.contains("Margin sharing star could not be saved"), true)
        XCTAssertEqual(fixture.model.selectedItem.interjections, before, "nothing on screen changed")
        XCTAssertNil(try fixture.store.loadInterjections(sessionId: fixture.currentSessionId).first { $0.id == "m-missing" }, "nothing was invented in the store")
    }
}
