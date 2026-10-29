import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2506: the Library's summaries and the shared packet matcher read small records kept beside each item, not the
/// item's text. The records are a cache: the stored item is the truth, and anything that doesn't match it is ignored.
final class ItemDerivedRecordsTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func build() throws -> LibraryFixture {
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        return fixture
    }

    private func records(_ kind: String, at fixture: LibraryFixture) throws -> Int {
        Int(try XCTUnwrap(try StoreRawSQL.rows("SELECT COUNT(*) FROM records WHERE kind = ?;", bindings: [kind], at: fixture.databaseURL.path).first?.first ?? nil)) ?? -1
    }

    /// A stand-in for the real hashing: the call count is what a test pins, and the answer depends on the text.
    private final class CountingHasher: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var texts: [String] = []
        func digests(_ text: String) -> ItemTextDigests {
            lock.lock(); defer { lock.unlock() }
            texts.append(text)
            return ItemTextDigests(normalizedContentSHA256: "n:\(text.count):\(text.prefix(8))", exactEditionSHA256: "e:\(text.count):\(text.prefix(8))")
        }
    }

    // MARK: Summaries

    func testASummaryReadStoresASliceForEveryItemAndTheNextReadGivesTheSameAnswer() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        XCTAssertEqual(try records("item_slice", at: fixture), 0, "the fixture was written without any")

        let cold = try store.listItemSummaries(includeDeleted: true)
        XCTAssertEqual(try records("item_slice", at: fixture), cold.count)
        let warm = try store.listItemSummaries(includeDeleted: true)

        XCTAssertEqual(warm, cold)
        XCTAssertEqual(cold, try store.listItems(includeDeleted: true).map(LibraryItemSummary.init), "what the whole items say")
    }

    func testAWarmReadNeverTouchesTheItemPayloads() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let cold = try store.listItemSummaries()
        // Change an article's text without changing the row's time or size: a read that looked at the payload would see
        // the new text count. The stored record, which names the row it was cut from, still answers.
        let id = fixture.articleItemId
        let before = try store.loadItem(id: id)
        var edited = try XCTUnwrap(before.text)
        edited.removeFirst()
        edited.insert(edited.first == "Z" ? "Y" : "Z", at: edited.startIndex)
        try StoreRawSQL.execute(
            "UPDATE records SET payload = replace(payload, ?, ?) WHERE kind = 'item' AND id = ?;",
            bindings: [String(try XCTUnwrap(before.text).prefix(40)), String(edited.prefix(40)), id], at: fixture.databaseURL.path)
        let meter = StoreReadMeter()
        let warmStore = try fixture.openStore(meter: meter)

        XCTAssertEqual(try warmStore.listItemSummaries(), cold)
        XCTAssertEqual(meter.totals(for: "listItemSummaries(includeDeleted:)").rows, cold.count)
    }

    func testAnItemSavedAfterwardsIsReadAgain() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        _ = try store.listItemSummaries()
        var item = try store.loadItem(id: fixture.articleItemId)
        item.title = "A new title"
        item.text = "Short."
        item.status = "played"
        try store.saveItem(item)

        let summary = try XCTUnwrap(try store.loadItemSummary(id: item.id))

        XCTAssertEqual(summary, LibraryItemSummary(item))
        XCTAssertEqual(summary.textCharacterCount, 6)
        XCTAssertEqual(try store.listItemSummaries().first { $0.id == item.id }, summary)
    }

    /// An older build writes the item and knows nothing of the records. Its save moves the row's time; these tests set
    /// it by hand, as that save would, since both saves would land inside one second.
    func testAnItemAnOlderBuildSavedIsReadAgain() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        _ = try store.listItemSummaries()
        let id = fixture.articleItemId
        try StoreRawSQL.execute(
            "UPDATE records SET payload = replace(payload, '\"status\":\"' || json_extract(payload, '$.status') || '\"', '\"status\":\"archived\"'), updated_at = '2999-01-01 00:00:00' WHERE kind = 'item' AND id = ?;",
            bindings: [id], at: fixture.databaseURL.path)

        XCTAssertEqual(try store.loadItemSummary(id: id)?.status, "archived")
        XCTAssertEqual(try store.listItemSummaries().first { $0.id == id }?.status, "archived")
    }

    func testAnItemSavedWhileTheSecondIsStillRunningStaysCurrent() throws {
        // Two saves inside one second leave the same `updated_at`; `saveItem` forgets what it derived, so the
        // second still wins.
        let fixture = try build()
        let store = try fixture.openStore()
        var item = try store.loadItem(id: fixture.articleItemId)
        item.status = "queued"
        try store.saveItem(item)
        XCTAssertEqual(try store.loadItemSummary(id: item.id)?.status, "queued")
        XCTAssertEqual(try records("item_slice", at: fixture), 1)
        item.status = "played"
        try store.saveItem(item)
        XCTAssertEqual(try records("item_slice", at: fixture), 0, "saving the item forgot the record")
        XCTAssertEqual(try store.loadItemSummary(id: item.id)?.status, "played")
    }

    func testDeletingAnItemDeletesItsRecords() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let rows = try store.listItemSummaries(includeDeleted: true)
        let hasher = CountingHasher()
        _ = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: hasher.digests)
        XCTAssertEqual(try records("item_slice", at: fixture), rows.count)

        try store.deleteItem(id: fixture.articleItemId)

        XCTAssertEqual(try records("item_slice", at: fixture), rows.count - 1)
        XCTAssertEqual(try StoreRawSQL.rows("SELECT id FROM records WHERE kind = 'item_text_digest' AND id = ?;", bindings: [fixture.articleItemId], at: fixture.databaseURL.path).count, 0)
    }

    func testSummariesStillComeBackWhenTheRecordsCannotBeWritten() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let expected = try store.listItemSummaries()
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = 'item_slice';", at: fixture.databaseURL.path)
        try StoreRawSQL.execute("CREATE TRIGGER no_slices BEFORE INSERT ON records WHEN NEW.kind = 'item_slice' BEGIN SELECT RAISE(ABORT, 'no'); END;", at: fixture.databaseURL.path)

        XCTAssertEqual(try store.listItemSummaries(), expected)
        XCTAssertEqual(try records("item_slice", at: fixture), 0)
    }

    func testARecordThatIsNotTheStoredShapeIsIgnored() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let expected = try store.listItemSummaries()
        try StoreRawSQL.execute("UPDATE records SET payload = '{\"format\":1}' WHERE kind = 'item_slice';", at: fixture.databaseURL.path)
        XCTAssertEqual(try store.listItemSummaries(), expected)
        try StoreRawSQL.execute("UPDATE records SET payload = replace(payload, '\"format\":1', '\"format\":99') WHERE kind = 'item_slice';", at: fixture.databaseURL.path)
        XCTAssertEqual(try store.listItemSummaries(), expected)
    }

    /// Build 32 and 34 open this file. They read only the kinds they know, so the new rows are invisible to them: every
    /// reader of the old kinds gives the same answer with and without the records.
    func testTheOldReadersAnswerTheSameWithTheRecordsPresent() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let before = try store.listItems(includeDeleted: true)
        let sessionsBefore = try store.loadSessions().count
        _ = try store.listItemSummaries()
        _ = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: CountingHasher().digests)

        XCTAssertEqual(try store.listItems(includeDeleted: true), before)
        XCTAssertEqual(try store.loadSessions().count, sessionsBefore)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        XCTAssertEqual(try SQLiteSessionStore.schemaVersion(atPath: fixture.databaseURL.path), SQLiteSessionStore.currentSchemaVersion,
                       "no schema change: the table and its version are as they were")
    }

    // MARK: Digests

    func testMatchingRowsAreTheLiveItemsInTheOrderOfListItemsWithoutTheirText() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        try store.moveItemToTrash(id: fixture.articleItemId)
        let hasher = CountingHasher()

        let rows = try store.listItemsForMatching(format: "t", needsDigests: { $0.media == nil }, digests: hasher.digests)
        let items = try store.listItems()

        XCTAssertEqual(rows.map(\.item.id), items.map(\.id))
        XCTAssertFalse(rows.contains { $0.item.id == fixture.articleItemId })
        for (row, item) in zip(rows, items) {
            var withoutText = item
            withoutText.text = nil
            withoutText.documentStructure = nil
            XCTAssertEqual(row.item, withoutText)
            XCTAssertEqual(row.textDigests, item.media == nil ? hasher.digests(item.text ?? "") : nil, item.id)
        }
    }

    func testEachItemsTextIsHashedOnceAndNeverAgain() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let first = CountingHasher()
        let rows = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: first.digests)
        let texts = Set(first.texts)
        XCTAssertGreaterThan(texts.count, 10, "the fixture's articles are all different")

        let second = CountingHasher()
        let again = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: second.digests)

        XCTAssertEqual(again.map(\.textDigests), rows.map(\.textDigests))
        // An item with no text hashes the empty string once per match, which costs nothing and keeps no record.
        XCTAssertEqual(second.texts.filter { !$0.isEmpty }, [], "the digests were kept")
    }

    func testAnItemWithNoTextIsHashedAsTheEmptyText() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        try store.saveItem(Item(id: "no-text", title: "No text", mediaType: "text", text: nil, externalReference: nil, status: "ready"))
        let hasher = CountingHasher()

        let row = try XCTUnwrap(try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: hasher.digests).first { $0.item.id == "no-text" })

        XCTAssertEqual(row.textDigests, hasher.digests(""))
    }

    func testOnlyAnItemThatChangedIsHashedAgain() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        _ = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: CountingHasher().digests)
        var item = try store.loadItem(id: fixture.articleItemId)
        item.text = "The edition was corrected."
        try store.saveItem(item)
        let hasher = CountingHasher()

        let rows = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: hasher.digests)

        XCTAssertEqual(hasher.texts.filter { !$0.isEmpty }, ["The edition was corrected."])
        XCTAssertEqual(rows.first { $0.item.id == item.id }?.textDigests, hasher.digests("The edition was corrected."))
    }

    func testADigestMadeUnderAnotherFormatIsMadeAgain() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        let first = CountingHasher()
        _ = try store.listItemsForMatching(format: "1-26", needsDigests: { _ in true }, digests: first.digests)
        let second = CountingHasher()

        _ = try store.listItemsForMatching(format: "1-27", needsDigests: { _ in true }, digests: second.digests)

        XCTAssertEqual(Set(second.texts), Set(first.texts))
    }

    func testMatchingReadsFarLessThanTheWholeLibrary() throws {
        let fixture = try build()
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        _ = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: CountingHasher().digests)
        meter.reset()

        _ = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: CountingHasher().digests)
        let warm = meter.samples.reduce(0) { $0 + $1.bytes }
        meter.reset()
        _ = try store.listItems()
        let whole = meter.totals(for: "listItems(includeDeleted:)").bytes

        XCTAssertGreaterThan(whole, 500_000)
        XCTAssertLessThan(warm, whole / 10, "a match reads kept records: \(warm) bytes against \(whole)")
    }

    func testAMatchWhenARowCannotBeCutFallsBackToTheWholeRead() throws {
        let fixture = try build()
        let store = try fixture.openStore()
        try StoreRawSQL.execute("UPDATE records SET payload = 'not json' WHERE kind = 'item' AND id = ?;", bindings: [fixture.articleItemId], at: fixture.databaseURL.path)
        let hasher = CountingHasher()

        let rows = try store.listItemsForMatching(format: "t", needsDigests: { _ in true }, digests: hasher.digests)

        XCTAssertFalse(rows.contains { $0.item.id == fixture.articleItemId })
        XCTAssertEqual(try store.quarantinedRecordCount(), 1, "the broken record was set aside, as a whole read does")
    }
}
