import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #1991: the real database gives the Today's Margins shortcut the day's Margins, off the caller's actor.
final class StoreReaderTodaysMarginsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("todays-margins-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func seed(_ store: SQLiteSessionStore, itemId: String, title: String, deleted: Bool = false, margins: [(String, Date, String)]) throws {
        try store.saveItem(Item(
            id: itemId, title: title, mediaType: "text", text: "Body text that must not be needed.", externalReference: nil,
            status: "ready", deletedAt: deleted ? Date(timeIntervalSince1970: 1_000) : nil))
        let session = Session(
            id: "s-\(itemId)", itemId: itemId, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: itemId, position: Position(), completionPercent: 10, playbackRate: 1)
        try store.saveSession(session)
        for (id, created, words) in margins {
            try store.saveInterjection(Interjection(
                id: id, itemId: itemId, sessionId: session.id, targetType: .item, targetId: itemId, createdAt: created, roughPercent: 25,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed", transcript: words, cleanedTranscript: nil,
                displayText: words, status: "active", captureKind: .written))
        }
    }

    func testReadsOnlyTheDaysMarginsOfLiveItemsInTimeOrder() async throws {
        let store = try makeStore()
        let noon = Date(timeIntervalSince1970: 1_794_484_800) // 2026-11-12 12:00 UTC
        try seed(store, itemId: "a", title: "Alpha", margins: [
            ("a-late", noon.addingTimeInterval(600), "late"), ("a-yesterday", noon.addingTimeInterval(-86_400), "yesterday"),
        ])
        try seed(store, itemId: "b", title: "Bravo", margins: [("b-early", noon.addingTimeInterval(-600), "early")])
        try seed(store, itemId: "d", title: "Deleted", deleted: true, margins: [("d-today", noon, "from the trash")])
        try seed(store, itemId: "e", title: "Empty", margins: [])

        let found = try await StoreReader(store).todaysMargins(on: noon, calendar: calendar)
        XCTAssertEqual(found.map(\.id), ["b-early", "a-late"])
        XCTAssertEqual(found.map(\.itemTitle), ["Bravo", "Alpha"])
        XCTAssertEqual(found.map(\.words), ["early", "late"])
    }

    func testAnEmptyLibraryGivesAnEmptyDay() async throws {
        let found = try await StoreReader(try makeStore()).todaysMargins(on: Date(), calendar: calendar)
        XCTAssertEqual(found, [])
    }
}
