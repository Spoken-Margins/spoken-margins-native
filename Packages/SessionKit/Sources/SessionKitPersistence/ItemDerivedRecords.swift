import Foundation
import SessionKit
import SQLite3

// Records derived from an item's stored row, so a read that needs only a title, a count or a digest does not copy and
// parse the article's text every time (#2506). They are ordinary rows of the `records` table under kinds of their own,
// so the table layout and the schema version stay as they were and an older build, which reads only the kinds it
// knows, ignores them. They are a cache and nothing else: the item row is the truth, and each record names the row
// it was derived from (its `updated_at` and its size in bytes). A record that doesn't match the row now there, whether
// this build or an older one wrote the item, is ignored and made again.

/// An item without its `text` and `documentStructure`, and the two facts about the text a Library row needs.
struct ItemSlice: Sendable {
    var item: Item
    var textCharacterCount: Int?
    var hasListenableText: Bool
    /// The stored row this was cut from.
    var token: ItemRowToken
}

/// Names one version of an item's stored row. `updated_at` moves on every save; the byte size backs it up for two saves
/// inside the same second.
struct ItemRowToken: Codable, Equatable, Sendable {
    var updatedAt: String
    var bytes: Int
}

private struct StoredItemSlice: Codable {
    static let currentFormat = 1
    var format: Int
    var token: ItemRowToken
    var item: Item
    var textCharacterCount: Int?
    var hasListenableText: Bool
}

private struct StoredItemTextDigests: Codable {
    var format: String
    var itemId: String
    var token: ItemRowToken
    var digests: ItemTextDigests
}

/// An item (without its text unless the store had to read the whole Library) and its text digests, for the shared
/// packet matcher. `textDigests` is nil for an item the caller said needs none.
public struct ItemMatchRow: Sendable {
    public var item: Item
    public var textDigests: ItemTextDigests?
}

extension SQLiteSessionStore {
    static let itemSliceKind = "item_slice"
    static let itemTextDigestKind = "item_text_digest"
    /// How many stale or missing slices are cut one by one; past this the whole table is cut in one pass.
    private static let sliceRepairOneByOneLimit = 24
    /// How much of an item's text the slice looks at to tell whether there is any besides whitespace.
    static let sliceTextHeadLength = 512

    func forgetDerivedRecords(ofItem id: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE kind IN ('\(Self.itemSliceKind)', '\(Self.itemTextDigestKind)') AND id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_forget_derived")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_forget_derived")
            }
        }
    }

    // MARK: Slices

    /// Every item (or the one named), deleted ones included, in `listItems`' order, each without its text. A slice
    /// whose stored record still matches its row is used as stored; any other is cut from the row by SQLite, so the
    /// text is never copied, and stored for next time. nil when a row can't be cut or decoded: the caller reads
    /// the whole way, which sets the broken record aside.
    func itemSlices(onlyId: String?, method: String) throws -> [ItemSlice]? {
        let generation = itemRevisionLock.withLock { itemWriteGeneration }
        let timer = StoreReadTimer(readMeter, method: method)
        var rowCount = 0
        var byteCount = 0
        defer { timer?.finish(rows: rowCount, bytes: byteCount) }

        let rows = try storedRows(onlyId: onlyId)
        var found: [String: ItemSlice] = [:]
        var stale: [(id: String, token: ItemRowToken)] = []
        for row in rows {
            byteCount += row.cached?.utf8.count ?? 0
            if let cached = row.cached, let data = cached.data(using: .utf8),
               let stored = try? decoder.decode(StoredItemSlice.self, from: data),
               stored.format == StoredItemSlice.currentFormat, stored.token == row.token, stored.item.id == row.id {
                found[row.id] = ItemSlice(item: stored.item, textCharacterCount: stored.textCharacterCount,
                                          hasListenableText: stored.hasListenableText, token: stored.token)
            } else {
                stale.append((row.id, row.token))
            }
        }
        if !stale.isEmpty {
            let cutAll = onlyId == nil && (stale.count > Self.sliceRepairOneByOneLimit || stale.count == rows.count)
            guard let cut = try cutSlices(ids: cutAll ? nil : stale.map(\.id), byteCount: &byteCount) else { return nil }
            let wanted = Set(stale.map(\.id))
            var fresh: [ItemSlice] = []
            for slice in cut where wanted.contains(slice.item.id) {
                found[slice.item.id] = slice
                fresh.append(slice)
            }
            storeSlices(fresh, ifNoItemWrittenSince: generation)
        }
        // A row saved between the listing and the cut is cut at its new state; one deleted in between has no slice.
        let slices = rows.compactMap { found[$0.id] }
        rowCount = slices.count
        return slices
    }

    private struct StoredRow {
        var id: String
        var token: ItemRowToken
        var cached: String?
    }

    /// The item rows' identities, newest first, with the stored slice record beside each if there is one. SQLite reads
    /// each row's size and time without copying its payload.
    private func storedRows(onlyId: String?) throws -> [StoredRow] {
        var rows: [StoredRow] = []
        try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT i.id, i.updated_at, length(CAST(i.payload AS BLOB)), d.payload
                FROM records AS i
                LEFT JOIN records AS d ON d.kind = '\(Self.itemSliceKind)' AND d.id = i.id
                WHERE i.kind = 'item'\(onlyId == nil ? "" : " AND i.id = ?")
                ORDER BY i.updated_at DESC, i.id;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_item_slice_rows")
            }
            defer { sqlite3_finalize(statement) }
            if let onlyId { bind(statement, index: 1, value: onlyId) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_item_slice_rows") }
                guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
                rows.append(StoredRow(
                    id: id,
                    token: ItemRowToken(
                        updatedAt: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                        bytes: Int(sqlite3_column_int64(statement, 2))),
                    cached: sqlite3_column_text(statement, 3).map { String(cString: $0) }))
            }
        }
        return rows
    }

    /// Cuts the text and structure out of the rows of `ids` (all items for nil) in SQLite, newest first. The text's
    /// length is counted in Unicode scalars, which is how SQLite counts; it differs from Swift's character count only
    /// for text with combining marks or joined emoji, and only feeds the listening-time estimate.
    private func cutSlices(ids: [String]?, byteCount: inout Int) throws -> [ItemSlice]? {
        var raw: [(id: String, payload: String, head: String?, length: Int?, token: ItemRowToken)] = []
        try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT id,
                       CASE WHEN json_valid(payload) THEN json_remove(payload, '$.text', '$.documentStructure') END,
                       substr(CASE WHEN json_valid(payload) THEN json_extract(payload, '$.text') END, 1, \(Self.sliceTextHeadLength)),
                       CASE WHEN json_valid(payload) THEN length(json_extract(payload, '$.text')) END,
                       updated_at, length(CAST(payload AS BLOB))
                FROM records WHERE kind = 'item'\(ids == nil ? "" : " AND id = ?") ORDER BY updated_at DESC, id;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_item_slices")
            }
            defer { sqlite3_finalize(statement) }
            func collect() throws {
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_DONE { return }
                    guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_item_slices") }
                    guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                          let payload = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                        raw.append((id: "", payload: "", head: nil, length: nil, token: ItemRowToken(updatedAt: "", bytes: 0)))
                        continue
                    }
                    raw.append((
                        id: id, payload: payload,
                        head: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                        length: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 3)),
                        token: ItemRowToken(
                            updatedAt: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
                            bytes: Int(sqlite3_column_int64(statement, 5)))))
                }
            }
            if let ids {
                for id in ids {
                    sqlite3_reset(statement)
                    bind(statement, index: 1, value: id)
                    try collect()
                }
            } else {
                try collect()
            }
        }
        var slices: [ItemSlice] = []
        for row in raw {
            byteCount += row.payload.utf8.count + (row.head?.utf8.count ?? 0)
            guard !row.id.isEmpty, let data = row.payload.data(using: .utf8),
                  let item = try? decoder.decode(Item.self, from: data) else { return nil }
            var hasText = row.head?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            if !hasText, (row.length ?? 0) > Self.sliceTextHeadLength {
                // Whitespace for the first stretch, then maybe words: only this rare item is read whole.
                hasText = (try? loadItem(id: item.id))?.hasListenableText ?? false
            }
            slices.append(ItemSlice(item: item, textCharacterCount: row.length, hasListenableText: hasText, token: row.token))
        }
        return slices
    }

    /// Keeps the slices for the next read. A cache write, never worth making a read wait: it is skipped when another
    /// thread holds the write connection, and when any item was written since the read began (the slices may already
    /// be out of date). A failure to write is ignored.
    private func storeSlices(_ slices: [ItemSlice], ifNoItemWrittenSince generation: Int) {
        guard !slices.isEmpty, connectionLock.try() else { return }
        defer { connectionLock.unlock() }
        guard itemRevisionLock.withLock({ itemWriteGeneration }) == generation else { return }
        try? withTransaction {
            for slice in slices {
                try save(kind: Self.itemSliceKind, id: slice.item.id, sessionId: nil, itemId: slice.item.id,
                         value: StoredItemSlice(format: StoredItemSlice.currentFormat, token: slice.token, item: slice.item,
                                                textCharacterCount: slice.textCharacterCount,
                                                hasListenableText: slice.hasListenableText))
            }
        }
    }

    func librarySummaries(from slices: [ItemSlice]) -> [LibraryItemSummary] {
        slices.map { slice in
            let item = slice.item
            return LibraryItemSummary(
                id: item.id, title: item.title, mediaType: item.mediaType, status: item.status,
                externalReference: item.externalReference, externalReferenceType: item.externalReferenceType,
                media: item.media, deletedAt: item.deletedAt, author: item.author, sourceTitle: item.sourceTitle,
                sourceURL: item.sourceURL, createdAt: item.createdAt, publishedAt: item.publishedAt,
                sourceCompletedAt: item.sourceCompletedAt, hasListenableText: slice.hasListenableText,
                textCharacterCount: slice.textCharacterCount)
        }
    }

    // MARK: Text digests

    /// The Library's live items for the shared packet matcher (#2506): the same items in the same order as
    /// `listItems()`, but without their text, and with the digests the matcher compares in place of hashing the text.
    ///
    /// `needsDigests` says which items are matched by their text (an episode of a podcast is not). Digests are read
    /// from the records kept beside the items; for an item without a current record, the text is read once, hashed by
    /// `digests`, and the answer kept. `format` names the hashing: a record made under another format is made again.
    public func listItemsForMatching(
        format: String,
        needsDigests: (Item) -> Bool,
        digests: (String) -> ItemTextDigests
    ) throws -> [ItemMatchRow] {
        let method = #function
        let generation = itemRevisionLock.withLock { itemWriteGeneration }
        guard let slices = try itemSlices(onlyId: nil, method: method) else {
            // Something couldn't be cut: read the whole way, which also sets the broken record aside.
            return try listItems().map { item in
                ItemMatchRow(item: item, textDigests: needsDigests(item) ? digests(item.text ?? "") : nil)
            }
        }
        let live = slices.filter { $0.item.deletedAt == nil }
        let wanting = live.filter { needsDigests($0.item) }
        let timer = StoreReadTimer(readMeter, method: method + ".digests")
        var bytes = 0
        var current = try currentDigests(format: format, byteCount: &bytes)
        var emptyText: ItemTextDigests?
        var fresh: [StoredItemTextDigests] = []
        var unreadable = Set<String>()
        for slice in wanting {
            let id = slice.item.id
            if let have = current[id], have.token == slice.token { continue }
            if slice.textCharacterCount == nil {
                // No text at all: every such item hashes the same empty string.
                let empty = emptyText ?? digests("")
                emptyText = empty
                current[id] = StoredItemTextDigests(format: format, itemId: id, token: slice.token, digests: empty)
                continue
            }
            guard let whole = try wholeRow(id: id, byteCount: &bytes) else { unreadable.insert(id); continue }
            let record = StoredItemTextDigests(format: format, itemId: id, token: whole.token, digests: digests(whole.item.text ?? ""))
            current[id] = record
            fresh.append(record)
        }
        timer?.finish(rows: wanting.count, bytes: bytes)
        storeDigests(fresh, ifNoItemWrittenSince: generation)
        return live.compactMap { slice in
            let id = slice.item.id
            if unreadable.contains(id) { return nil }
            return ItemMatchRow(item: slice.item, textDigests: needsDigests(slice.item) ? current[id]?.digests : nil)
        }
    }

    private func currentDigests(format: String, byteCount: inout Int) throws -> [String: StoredItemTextDigests] {
        var stored: [String: StoredItemTextDigests] = [:]
        var payloads: [String] = []
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT payload FROM records WHERE kind = '\(Self.itemTextDigestKind)';",
                                     -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_item_text_digests")
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0) { payloads.append(String(cString: raw)) }
            }
        }
        for payload in payloads {
            byteCount += payload.utf8.count
            guard let data = payload.data(using: .utf8), let record = try? decoder.decode(StoredItemTextDigests.self, from: data),
                  record.format == format else { continue }
            stored[record.itemId] = record
        }
        return stored
    }
    /// One item as stored, with the token of the row it was read from.
    private func wholeRow(id: String, byteCount: inout Int) throws -> (item: Item, token: ItemRowToken)? {
        var found: (payload: String, token: ItemRowToken)?
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT payload, updated_at, length(CAST(payload AS BLOB)) FROM records WHERE kind = 'item' AND id = ?;",
                                     -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_item_whole_row")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: id)
            guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return }
            found = (String(cString: raw), ItemRowToken(
                updatedAt: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                bytes: Int(sqlite3_column_int64(statement, 2))))
        }
        guard let found else { return nil }
        byteCount += found.payload.utf8.count
        guard let data = found.payload.data(using: .utf8), let item = try? decoder.decode(Item.self, from: data) else { return nil }
        return (item, found.token)
    }

    /// Kept for the next match, on the same terms as `storeSlices`.
    private func storeDigests(_ records: [StoredItemTextDigests], ifNoItemWrittenSince generation: Int) {
        guard !records.isEmpty, connectionLock.try() else { return }
        defer { connectionLock.unlock() }
        guard itemRevisionLock.withLock({ itemWriteGeneration }) == generation else { return }
        try? withTransaction {
            for record in records {
                try save(kind: Self.itemTextDigestKind, id: record.itemId, sessionId: nil, itemId: record.itemId, value: record)
            }
        }
    }
}
