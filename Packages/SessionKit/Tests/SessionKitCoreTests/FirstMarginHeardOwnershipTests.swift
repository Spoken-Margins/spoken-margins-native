import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4711 / #2256: whose Margin a Margin moment voiced is read from the store by one row, so the app can read it off the
/// main thread at every voice end. Real SQLite.
final class FirstMarginHeardOwnershipTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("first-heard-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: "Notes", mediaType: "text", text: "First line.\n\nSecond line.", externalReference: "live-session",
             status: "needs_listening_map", externalReferenceType: "manual", createdAt: Date(timeIntervalSince1970: 1))
    }

    func testOnlyTheListenersOwnSpokenMarginOnThisItemCounts() throws {
        let store = try makeStore()
        var spoken = LiveSessionAlignment.Placed(id: "s", text: "Spoken Margin", offsetMs: 0, charOffset: 0)
        spoken.audioPath = "Margins/own.m4a"
        spoken.transcript = "Mine"
        let written = LiveSessionAlignment.Placed(id: "w", text: "Written", offsetMs: 0, charOffset: 13)
        let linked = try LiveSessionWrites.saveTextItem(item("item-a"), placed: [spoken, written], in: store)
        let spokenSaved = try XCTUnwrap(linked.first { $0.liveId == "s" }?.saved)
        let writtenSaved = try XCTUnwrap(linked.first { $0.liveId == "w" }?.saved)
        func identity(_ margin: Interjection) -> String { MarginIdentity.make(sessionId: margin.sessionId, interjectionId: margin.id) }

        XCTAssertTrue(MarginHearing.isListenersOwnSpokenMargin(marginIdentity: identity(spokenSaved), itemId: "item-a", repository: store))
        XCTAssertFalse(MarginHearing.isListenersOwnSpokenMargin(marginIdentity: identity(spokenSaved), itemId: "item-b", repository: store),
                       "another item's moment")
        XCTAssertFalse(MarginHearing.isListenersOwnSpokenMargin(marginIdentity: identity(writtenSaved), itemId: "item-a", repository: store),
                       "a written Margin has no voice")
        let heard = MarginHearing.spokenVoiceEnded(marginIdentity: identity(spokenSaved), itemId: "item-a", reachedEnd: true, repository: store)
        XCTAssertEqual(heard, MarginHearing(isListenersOwn: true, kind: .spoken, outcome: .reachedEnd))
        XCTAssertTrue(OnboardingProgress.firesFirstMarginHeard(heard))
        for other in ["", spokenSaved.id, "\(spokenSaved.sessionId)::missing", "friend-margin-1"] {
            XCTAssertFalse(MarginHearing.isListenersOwnSpokenMargin(marginIdentity: other, itemId: "item-a", repository: store), other)
        }
    }
}
