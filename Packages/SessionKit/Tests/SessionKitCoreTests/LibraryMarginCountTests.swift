import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2394: a Library row says how many Margins the listener has on it, so a nearly-finished item can be cleared
/// without opening it to look. The count comes from SQL over the real store, not from decoding every Margin.
final class LibraryMarginCountTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )
    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "margin-count-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        for id in ["none", "one", "three"] {
            try store.saveItem(Item(id: id, title: "Article \(id)", mediaType: "text", text: "First sentence. Second sentence.", externalReference: nil, status: "ready"))
        }
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `count` written Margins on the item, each in a session of its own, so the count is per item and not per session.
    private func writeMargins(_ count: Int, on itemId: String) throws {
        for index in 0..<count {
            let engine = SessionEngine(profile: profile, repository: store)
            _ = try engine.startSession(itemId: itemId)
            let capture = try engine.beginWrittenInterjection()
            _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Note \(index) on \(itemId).")
        }
    }

    func testTheStoreCountsEachItemsActiveMarginsAndLeavesOutDeletedOnes() throws {
        XCTAssertEqual(try store.loadActiveMarginCountsByItem(), [:], "nothing recorded yet")
        try writeMargins(1, on: "one")
        try writeMargins(3, on: "three")
        XCTAssertEqual(try store.loadActiveMarginCountsByItem(), ["one": 1, "three": 3])

        var removed = try XCTUnwrap(store.loadInterjections(itemId: "three").first)
        removed.status = "deleted"
        try store.saveInterjection(removed)
        XCTAssertEqual(try store.loadActiveMarginCountsByItem(), ["one": 1, "three": 2], "a deleted Margin no longer counts")
    }

    func testTheLibraryRowsCarryTheCountAndStayQuietAtZero() throws {
        try writeMargins(1, on: "one")
        try writeMargins(3, on: "three")
        let context = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: false)
        let rows = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: context)
        let counts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.marginCount) })
        XCTAssertEqual(counts, ["none": 0, "one": 1, "three": 3])
    }

    func testTheWordsAreSingularOrPluralAndAbsentAtZero() {
        XCTAssertNil(LibraryRowWording.marginCountLine(0))
        XCTAssertNil(LibraryRowWording.marginCountLine(-2), "a bad count says nothing")
        XCTAssertEqual(LibraryRowWording.marginCountLine(1), "1 Margin")
        XCTAssertEqual(LibraryRowWording.marginCountLine(2), "2 Margins")
        XCTAssertEqual(LibraryRowWording.marginCountLine(12), "12 Margins")
    }

    func testTheCountIsMadeInSQLLikeTheOtherLibraryReads() throws {
        try writeMargins(3, on: "three")
        let meter = StoreReadMeter()
        let metered = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path, readMeter: meter)
        _ = try metered.loadActiveMarginCountsByItem()
        let asked = meter.totals(for: "loadActiveMarginCountsByItem()")
        XCTAssertEqual(asked.rows, 1, "one row per item with Margins, however many Margins or sessions it has")
        XCTAssertEqual(asked.bytes, 0, "no payload is copied")
    }
}
