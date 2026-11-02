import Foundation
import SessionKit
import SQLite3

/// What the Item screen needs from a source transcript timeline without its segments (#2073).
public struct TranscriptTimelineSummary: Equatable, Sendable {
    public var chapters: [MediaTimelineChapter]
    public var durationMs: Int?

    public init(chapters: [MediaTimelineChapter], durationMs: Int?) {
        self.chapters = chapters
        self.durationMs = durationMs
    }
}

public final class SQLiteSessionStore: SessionRepositoryTransaction, @unchecked Sendable {
    /// Schema 5 adds record kinds and optional payload fields to the generic
    /// records table; it does not change the SQLite table layout. Sharing builds
    /// must accept it so installing this lane over another active lane does not
    /// make the existing library appear empty.
    public static let currentSchemaVersion = 5
    /// The Library read, audio preparation, the map preparer and the placement passes can read together, and the main thread beside them.
    private static let readConnectionLimit = 6
    private static let sessionScopedRecordKinds: Set<String> = ["interjection", "turn", "ai_job"]
    var db: OpaquePointer?
    let connectionLock = NSRecursiveLock()
    /// How many `withTransaction` calls are open on this connection. Guarded by `connectionLock`.
    private var transactionDepth = 0
    /// Read-only connections for reads, so a read never waits for `connectionLock` or for another read (#2103).
    /// nil when the file can't be read beside the writer (not WAL, or in memory): reads then use the one connection.
    private var readConnections: ReadConnectionPool?
    /// The thread that has a transaction open on `db`, if any. Its reads must see its own uncommitted writes, so they
    /// stay on `db`; every other thread reads what is committed.
    private let transactionOwnerLock = NSLock()
    private var transactionOwner: pthread_t?
    /// Items written inside the open transaction. Only the thread that owns it touches this, under `connectionLock`.
    private var itemsWrittenInTransaction: [String] = []
    /// `loadTranscriptTimelineSummary` answers by item, with the stamp of the record they were read from. Its own lock, so
    /// answering from it never waits behind a write holding `connectionLock`.
    private let transcriptSummaryLock = NSLock()
    private var transcriptSummaryByItem: [String: (stamp: String, summary: TranscriptTimelineSummary)] = [:]
    private let anchorContextLock = NSLock()
    private var anchorContextByItem: [String: (stamp: String, contexts: [Int: SourceAnchorContext?])] = [:]
    private var anchorTimelineDecodeCount = 0
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    /// How often each item was written or deleted through this connection, for `itemRevision(id:)`.
    /// Its own lock, so a caller asking never waits behind a query holding `connectionLock`.
    let itemRevisionLock = NSLock()
    private var itemRevisions: [String: Int] = [:]
    /// Moved by `reset()`, which can remove any item.
    private var itemRevisionBase = 0
    /// Moves with every write that can change an item's stored row, inside the lock hold that makes the write, and
    /// again when a transaction ends. A read that is about to store a record derived from an item (#2506) checks it
    /// has not moved since the read began. Guarded by `itemRevisionLock`.
    var itemWriteGeneration = 0

    /// Counts each read when set (#2258). Fixed at init, so the unmetered app path needs no lock to check it.
    public let readMeter: StoreReadMeter?

    public init(path: String, readMeter: StoreReadMeter? = nil) throws {
        self.readMeter = readMeter
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("sqlite_open")
        }
        // WAL permits concurrent readers, but only one connection may write.
        // Allow brief independent transactions to finish instead of dropping a save.
        sqlite3_busy_timeout(db, 1_000)
        try migrate()
        // WAL lets readers run beside the writer. Without it (a file system that can't, or an in-memory database) a
        // second connection would see a different database or lock the writer out, so reads stay on the one connection.
        var journalMode = ""
        try? readTexts("PRAGMA journal_mode;", [], name: "journal_mode") { journalMode = $0 }
        if journalMode.lowercased() == "wal" { readConnections = ReadConnectionPool(path: path, limit: Self.readConnectionLimit) }
        // A record an older build couldn't read was set aside, not lost. If this build can read it, put it back (#1052).
        // Best effort: a failure here leaves the rows quarantined and must not stop the Library opening.
        try? restoreQuarantinedRecords()
    }

    deinit {
        readConnections?.close()
        sqlite3_close(db)
    }

    public func migrate() throws {
        try withConnectionLock {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        let existingVersion = try metadataValue(forKey: "schema_version").flatMap(Int.init)
        guard existingVersion.map({ [1, 2, 3, 4, Self.currentSchemaVersion].contains($0) }) ?? true else {
            throw SessionKitError.persistenceFailed("unsupported_schema_version:\(existingVersion ?? -1)")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            session_id TEXT,
            item_id TEXT,
            payload TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(kind, id)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS quarantined_records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            payload TEXT NOT NULL,
            decode_error TEXT NOT NULL,
            quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(kind, id)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS records_session_idx ON records(kind, session_id);")
        try execute("CREATE INDEX IF NOT EXISTS records_item_idx ON records(kind, item_id);")
        if existingVersion == 1 || existingVersion == 2 {
            try migrateSessionTimestamps()
        }
        if let existingVersion, existingVersion < 4 {
            try migrateSessionScopedRecordKeys()
        }
            try setMetadataValue("\(Self.currentSchemaVersion)", forKey: "schema_version")
        }
    }

    public func reset() throws {
        try withTransaction {
            try execute("DELETE FROM records;")
            try execute("DELETE FROM quarantined_records;")
        }
        itemRevisionLock.withLock { itemRevisionBase &+= 1; itemWriteGeneration &+= 1 }
    }

    public func quarantinedRecordCount() throws -> Int {
        let timer = StoreReadTimer(readMeter, method: #function)
        defer { timer?.finish(rows: 1, bytes: 0) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM quarantined_records;", -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_quarantine_count")
            }
            defer { if statement != nil { sqlite3_finalize(statement) } }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SessionKitError.persistenceFailed("step_quarantine_count")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// The `records` columns a restored row needs. `quarantined_records` doesn't keep them, so they are
    /// read back off the decoded value, the way each kind's save path sets them.
    private struct RestoredColumns {
        var sessionId: String?
        var itemId: String?
    }

    /// Moves every quarantined row this build can decode back into `records`, with the id, kind and bytes it
    /// had when it was set aside (#1052). A row this build still can't decode stays in quarantine untouched,
    /// as does one whose kind has no rule here, whose id a newer save has since taken in `records`, or whose
    /// listening map or canonical source has a live replacement for the item. One
    /// transaction: a failure puts everything back. No schema change, so an older build still opens the file.
    private func restoreQuarantinedRecords() throws {
        // Nearly every open has nothing set aside. Look first, so those opens never take the write lock.
        guard try quarantinedRecordCount() > 0 else { return }
        try withTransaction {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT kind, id, payload, quarantined_at FROM quarantined_records ORDER BY kind = 'imported_commentary_layer' DESC, kind, id;", -1, &statement, nil) == SQLITE_OK else {
                // Layers first: an imported Margin takes its item from its layer.
                throw SessionKitError.persistenceFailed("prepare_quarantine_restore_read")
            }
            var rows: [(kind: String, id: String, payload: String, quarantinedAt: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = sqlite3_column_text(statement, 0), let id = sqlite3_column_text(statement, 1),
                      let payload = sqlite3_column_text(statement, 2), let at = sqlite3_column_text(statement, 3) else { continue }
                rows.append((String(cString: kind), String(cString: id), String(cString: payload), String(cString: at)))
            }
            sqlite3_finalize(statement)
            for row in rows {
                guard let data = row.payload.data(using: .utf8),
                      let columns = restoredColumns(kind: row.kind, from: data),
                      try restoreRecord(row, columns: columns) else { continue }
                try deleteQuarantinedRow(kind: row.kind, id: row.id)
            }
        }
    }

    /// Whether the row went back. A live row with the same kind and id wins: it was saved after this one was set aside.
    private func restoreRecord(_ row: (kind: String, id: String, payload: String, quarantinedAt: String), columns: RestoredColumns) throws -> Bool {
        // A session-scoped row with the old un-prefixed id would sit beside the `session::id` row later saves write.
        if Self.sessionScopedRecordKinds.contains(row.kind), let sessionId = columns.sessionId,
           !row.id.hasPrefix("\(sessionId)::") { return false }
        switch row.kind {
        case "listening_map", "canonical_source":
            // Their save paths replace every row for the item, even when the id changes.
            // Keep the listener's replacement live and the old bytes safely set aside.
            if let itemId = columns.itemId,
               try liveRecordExists(sql: "SELECT 1 FROM records WHERE kind = ? AND item_id = ? LIMIT 1;", values: [row.kind, itemId]) { return false }
        case "imported_commentary_layer":
            // The same packet imported again while this layer was set aside is already in the Library.
            if try liveRecordExists(sql: "SELECT 1 FROM records WHERE kind = 'imported_commentary_layer' AND json_extract(payload, '$.packageDigest') = (SELECT json_extract(?, '$.packageDigest')) LIMIT 1;", values: [row.payload]) { return false }
        case "imported_commentary_interjection":
            // Its layer is restored first. One that isn't in the Library leaves the Margin set aside.
            if try !liveRecordExists(sql: "SELECT 1 FROM records WHERE kind = 'imported_commentary_layer' AND id = json_extract(?, '$.layerId') LIMIT 1;", values: [row.payload]) { return false }
        default: break
        }
        var statement: OpaquePointer?
        // `updated_at` isn't kept in quarantine; the time it was set aside is the closest, and keeps lists in order.
        let sql = """
        INSERT INTO records(kind, id, session_id, item_id, payload, updated_at)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, id) DO NOTHING;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine_restore")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: row.kind)
        bind(statement, index: 2, value: row.id)
        bind(statement, index: 3, value: columns.sessionId)
        bind(statement, index: 4, value: columns.itemId)
        bind(statement, index: 5, value: row.payload)
        bind(statement, index: 6, value: row.quarantinedAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine_restore")
        }
        guard sqlite3_changes(db) == 1 else { return false }
        if row.kind == "imported_commentary_interjection" {
            // Saved with the item of the layer it belongs to.
            var itemStatement: OpaquePointer?
            let itemSQL = """
            UPDATE records SET item_id = (
                SELECT layer.item_id FROM records AS layer
                WHERE layer.kind = 'imported_commentary_layer' AND layer.id = json_extract(records.payload, '$.layerId')
            ) WHERE kind = ? AND id = ?;
            """
            guard sqlite3_prepare_v2(db, itemSQL, -1, &itemStatement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_quarantine_restore_item")
            }
            defer { sqlite3_finalize(itemStatement) }
            bind(itemStatement, index: 1, value: row.kind)
            bind(itemStatement, index: 2, value: row.id)
            guard sqlite3_step(itemStatement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_quarantine_restore_item")
            }
        }
        return true
    }

    private func liveRecordExists(sql: String, values: [String]) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine_restore_check")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            bind(statement, index: Int32(index + 1), value: value)
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func deleteQuarantinedRow(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM quarantined_records WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine_restore_delete")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: kind)
        bind(statement, index: 2, value: id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine_restore_delete")
        }
    }

    /// The columns for `kind`, or nil when this build can't decode `data` as that kind or has no rule for it.
    /// Scope: the Margin and Library kinds below. Others (watch hand-offs, offline reservations, preparation jobs and manifests) stay
    /// quarantined until they get a rule. A kind joins this list with its save path's `session_id` and `item_id`, copied exactly.
    private func restoredColumns(kind: String, from data: Data) -> RestoredColumns? {
        func columns<T: Decodable>(_ type: T.Type, session: (T) -> String? = { _ in nil }, item: (T) -> String?) -> RestoredColumns? {
            guard let value = try? decoder.decode(T.self, from: data) else { return nil }
            return RestoredColumns(sessionId: session(value), itemId: item(value))
        }
        switch kind {
        case "item": return columns(Item.self, item: { $0.id })
        case "listening_map": return columns(ListeningMap.self, item: { $0.itemId })
        case "session": return columns(Session.self, session: { $0.id }, item: { $0.itemId })
        case "interjection": return columns(Interjection.self, session: { $0.sessionId }, item: { $0.itemId })
        case "turn": return columns(ConversationTurn.self, session: { $0.sessionId }, item: { _ in nil })
        case "ai_job": return columns(AIJob.self, session: { $0.sessionId }, item: { $0.itemId })
        case "interjection_share_revision": return columns(InterjectionShareRevision.self, session: { $0.sessionId }, item: { $0.itemId })
        case "imported_commentary_layer": return columns(ImportedCommentaryLayer.self, item: { $0.itemId })
        case "imported_commentary_interjection": return columns(ImportedCommentaryInterjection.self, item: { _ in nil })
        case "canonical_source": return columns(CanonicalSourcePackage.self, item: { $0.itemId })
        case "audio_asset": return columns(AudioAsset.self, item: { $0.itemId })
        case "source_transcript_timeline": return columns(SourceTranscriptTimeline.self, item: { $0.itemId })
        case "podcast_download": return columns(PodcastDownloadRecord.self, item: { $0.itemId })
        case "owned_offline_asset": return columns(OwnedOfflineAsset.self, item: { $0.itemId })
        case "feed_subscription": return columns(FeedSubscription.self, item: { _ in nil })
        case "feed_entry": return columns(FeedEntry.self, item: { _ in nil })
        case "item_collection": return columns(ItemCollection.self, item: { _ in nil })
        default: return nil
        }
    }

    public func loadItem(id: String) throws -> Item {
        try load(kind: "item", id: id)
    }

    public func saveItem(_ item: Item) throws {
        defer { noteItemWritten(item.id) }
        try withConnectionLock {
            try save(kind: "item", id: item.id, sessionId: nil, itemId: item.id, value: item)
            // What was derived from the old row no longer describes it (#2506). Same lock hold, so no reader's
            // stale write can land between the save and the delete.
            try forgetDerivedRecords(ofItem: item.id)
            itemRevisionLock.withLock { itemWriteGeneration &+= 1 }
        }
    }

    /// Moves whenever `saveItem`, `deleteItem(s)` or `reset` touched the item through this store, so
    /// a caller that watches an item's fields can skip reading it while the number stands still.
    /// It counts this connection's writes: another process writing the same file does not move it.
    public func itemRevision(id: String) -> Int {
        itemRevisionLock.withLock { itemRevisionBase &+ (itemRevisions[id] ?? 0) }
    }

    /// Called after the write, even a failed one, so a half-done write never hides a change.
    ///
    /// Inside a transaction other threads still read the rows from before it, so the id is noted again once the
    /// transaction has committed or rolled back: a reader that cached what it read under the first number sees a new one.
    private func noteItemWritten(_ id: String) {
        bumpItemRevision(id)
        if currentThreadHasTransactionOpen() { itemsWrittenInTransaction.append(id) }
    }

    private func bumpItemRevision(_ id: String) {
        itemRevisionLock.withLock { itemRevisions[id, default: 0] &+= 1; itemWriteGeneration &+= 1 }
    }

    public func loadListeningMap(itemId: String) throws -> ListeningMap? {
        let maps: [ListeningMap] = try loadByItem(kind: "listening_map", itemId: itemId)
        return maps.first
    }

    /// The id `loadListeningMap(itemId:)` would return, read from the row's id column: the map's JSON is never copied
    /// out or decoded (#2506). A row whose JSON is broken still counts here; the next whole read sets it aside.
    public func listeningMapId(itemId: String) throws -> String? {
        try recordIds(kind: "listening_map", itemId: itemId, name: #function).first
    }

    public func saveListeningMap(_ map: ListeningMap) throws {
        try withTransaction {
            try deleteRecords(kind: "listening_map", itemId: map.itemId)
            try save(kind: "listening_map", id: map.id, sessionId: nil, itemId: map.itemId, value: map)
        }
    }

    public func saveSession(_ session: Session) throws {
        try save(kind: "session", id: session.id, sessionId: session.id, itemId: session.itemId, value: session)
    }

    public func loadSession(id: String) throws -> Session? {
        try loadOptional(kind: "session", id: id)
    }

    public func loadSessions(itemId: String) throws -> [Session] {
        let sessions: [Session] = try loadByItem(kind: "session", itemId: itemId)
        return sessions.sorted(by: Self.isNewerSession)
    }

    public func loadSessions() throws -> [Session] {
        let sessions: [Session] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id DESC;",
            ["session"]
        )
        return sessions.sorted(by: Self.isNewerSession)
    }

    public func saveInterjection(_ interjection: Interjection) throws {
        try save(kind: "interjection", id: interjection.id, sessionId: interjection.sessionId, itemId: interjection.itemId, value: interjection)
    }

    public func loadInterjections(sessionId: String) throws -> [Interjection] {
        try loadBySession(kind: "interjection", sessionId: sessionId)
    }

    /// Makes a saved Margin a reply to `link`'s Margin, or independent when `link` is nil (#473). Only the link changes;
    /// the words, recording and place stay, and the stored payload is the same shape older builds read. Returns false
    /// when the session holds no such Margin. Packets already shared keep the link they were made with.
    @discardableResult
    public func updateReply(ofInterjection interjectionId: String, sessionId: String, to link: MarginReplyLink?) throws -> Bool {
        try updateInterjection(id: interjectionId, sessionId: sessionId) { $0.replyTo = link } != nil
    }

    /// Whether any session has a Margin that is still active: the yes or no onboarding wants where it used to decode
    /// every session and every Margin to look for one (#2506). SQLite stops at the first match and returns no payload.
    /// A Margin counts when its session is in the store, as when `loadInterjections(sessionId:)` was asked for each session.
    public func hasActiveInterjection() throws -> Bool {
        let timer = StoreReadTimer(readMeter, method: #function)
        var found = false
        defer { timer?.finish(rows: found ? 1 : 0, bytes: 0) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT 1 FROM records AS margin
                WHERE margin.kind = 'interjection'
                  AND CASE WHEN json_valid(margin.payload) THEN json_extract(margin.payload, '$.status') = 'active' ELSE 0 END
                  AND EXISTS (SELECT 1 FROM records AS session WHERE session.kind = 'session' AND session.id = margin.session_id)
                LIMIT 1;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_has_active_interjection")
            }
            defer { sqlite3_finalize(statement) }
            found = sqlite3_step(statement) == SQLITE_ROW
            return found
        }
    }

    /// How many active Margins each session has, for the sessions that have any: what the batch export list shows
    /// beside each session, where it used to decode every session's Margins to count them (#2506). The count is
    /// made in SQLite, so no payload is copied. A session with none is absent, as a count of zero.
    public func activeInterjectionCountsBySession() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let timer = StoreReadTimer(readMeter, method: #function)
        defer { timer?.finish(rows: counts.count, bytes: 0) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT session_id, count(*) FROM records
                WHERE kind = 'interjection' AND session_id IS NOT NULL
                  AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.status') = 'active' ELSE 0 END
                GROUP BY session_id;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_active_interjection_counts")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_active_interjection_counts") }
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                counts[String(cString: raw)] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        return counts
    }

    /// How many active Margins of the listener's own each item has, for the items that have any: the Library row's count
    /// (#2394). The count is made in SQLite from the `item_id` column, so no payload is copied; an item with none is
    /// absent, as a count of zero. Friends' Margins are counted apart (`loadSharedMarginTallies`).
    public func loadActiveMarginCountsByItem() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let timer = StoreReadTimer(readMeter, method: #function)
        defer { timer?.finish(rows: counts.count, bytes: 0) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT item_id, count(*) FROM records
                WHERE kind = 'interjection' AND item_id IS NOT NULL
                  AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.status') = 'active' ELSE 0 END
                GROUP BY item_id;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_active_margin_counts_by_item")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_active_margin_counts_by_item") }
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                counts[String(cString: raw)] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        return counts
    }

    /// The Margin rows `deleteItem(id:)` removes with the item: every row filed under it.
    public func loadInterjections(itemId: String) throws -> [Interjection] {
        try loadByItem(kind: "interjection", itemId: itemId)
    }

    /// Settles the voice Margins left "pending" by an earlier run of the app as "failed", so they offer Retry
    /// instead of promising work no one will do (#942). Call it once at launch, before any transcription of
    /// this run can start. Returns how many Margins it changed. Only the status of those Margins is written.
    @discardableResult
    public func settleOrphanedTranscriptions() throws -> Int {
        // "pending" is also an AI-job and turn status, so a text match only narrows the rows to decode.
        let candidates: [Interjection] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? AND payload LIKE '%\"pending\"%';",
            ["interjection"]
        )
        let settled = candidates.compactMap(OrphanedTranscription.settled)
        for margin in settled { try saveInterjection(margin) }
        return settled.count
    }

    /// Every audio path any stored Margin names, read from the stored JSON itself: live rows, rows that no
    /// longer decode as a Margin, and rows already moved to quarantine. It is the check that no Margin
    /// still uses a recording before the recording is deleted (#1035), so it fails closed: a row it can't
    /// read, or a read that doesn't reach the end of the table, throws instead of leaving a reference out.
    public func allMarginAudioPaths() throws -> [String] {
        let live = try marginAudioPaths(sql: "SELECT payload FROM records WHERE kind = 'interjection';", caller: "allMarginAudioPaths()")
        let quarantined = try marginAudioPaths(sql: "SELECT payload FROM quarantined_records WHERE kind = 'interjection';", caller: "allMarginAudioPaths()")
        return live + quarantined
    }

    /// Which sessions have Margins or AI turns saved after `after` (#1192), for the notes folder to rebuild their notes.
    /// `after` is a `settledThrough` from an earlier call, or nil for "everything", which names no sessions.
    ///
    /// It reads only Margin and turn rows. Their payloads are small, so the check is one short scan; an item's
    /// payload holds the whole article, and reading its `updated_at` would mean reading all of it.
    ///
    /// `updated_at` is whole seconds, so a row saved in the same second as a read could carry the read's own
    /// timestamp. `settledThrough` is therefore two seconds behind the database clock: the next call starts there
    /// and sees such a row again, and a write after the read can never land at or before it.
    public func marginNoteChanges(after: String?) throws -> MarginNoteChanges {
        var settled = ""
        try readTexts("SELECT strftime('%Y-%m-%d %H:%M:%S', 'now', '-2 seconds');", [], name: "margin_note_clock") { settled = $0 }
        guard let after else { return MarginNoteChanges(sessionIds: [], settledThrough: settled) }
        var sessionIds: Set<String> = []
        try readTexts(
            "SELECT DISTINCT session_id FROM records WHERE kind IN ('interjection', 'turn') AND updated_at > ?1 AND session_id IS NOT NULL;",
            [after], name: "margin_note_changes"
        ) { sessionIds.insert($0) }
        return MarginNoteChanges(sessionIds: sessionIds, settledThrough: settled)
    }

    /// How many bytes of source transcript each item has, to see a transcript arrive or change without reading it.
    /// An item can hold a chapters-only timeline first (publisher chapters) and its real transcript later, under the same
    /// row, so the size, not the presence, is what changes. `octet_length` (SQLite 3.43) reads the length from the row
    /// header; older SQLite falls back to `length`, which reads the whole payload.
    public func sourceTranscriptSizes() throws -> [String: Int] {
        func read(_ function: String) throws -> [String: Int] {
            var sizes: [String: Int] = [:]
            try readPairs(
                "SELECT item_id, \(function)(payload) FROM records WHERE kind = 'source_transcript_timeline' AND item_id IS NOT NULL;",
                name: "source_transcript_sizes"
            ) { sizes[$0, default: 0] += $1 }
            return sizes
        }
        do { return try read("octet_length") } catch { return try read("length") }
    }

    private func readPairs(_ sql: String, name: String, _ body: (String, Int) -> Void) throws {
        let timer = StoreReadTimer(readMeter, method: name)
        var rowCount = 0
        defer { timer?.finish(rows: rowCount, bytes: 0) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_\(name)")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_\(name)") }
                if let raw = sqlite3_column_text(statement, 0) {
                    rowCount += 1
                    body(String(cString: raw), Int(sqlite3_column_int64(statement, 1)))
                }
            }
        }
    }

    /// Internal so a test can hold a read open (a long statement) and watch what else the store still answers.
    func readTexts(_ sql: String, _ values: [String], name: String, _ body: (String) -> Void) throws {
        let timer = StoreReadTimer(readMeter, method: name)
        var rowCount = 0, byteCount = 0
        defer { timer?.finish(rows: rowCount, bytes: byteCount) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_\(name)")
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() { bind(statement, index: Int32(index + 1), value: value) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_\(name)") }
                if let raw = sqlite3_column_text(statement, 0) {
                    let text = String(cString: raw)
                    rowCount += 1
                    byteCount += text.utf8.count
                    body(text)
                }
            }
        }
    }

    /// The audio paths of the Margins quarantined under `itemId` (#1466): the recordings of rows this build
    /// can't decode, which `loadInterjections(itemId:)` doesn't return. Read them before `deleteItem(id:)`,
    /// which takes the rows, so the files that only those rows named can be removed too.
    ///
    /// A row whose JSON or audio path can't be read is skipped, not fatal: it must not make the delete
    /// impossible, and the recording it may name is then kept, never removed on a guess.
    public func quarantinedMarginAudioPaths(itemId: String) throws -> [String] {
        guard try quarantinedRecordCount() > 0 else { return [] }
        return try marginAudioPaths(
            sql: "SELECT payload FROM quarantined_records WHERE kind = 'interjection' AND (\(Self.quarantinedRowBelongsToItem));",
            bindings: [itemId], skippingUnreadable: true, caller: "quarantinedMarginAudioPaths(itemId:)")
    }

    private func marginAudioPaths(sql: String, bindings: [String] = [], skippingUnreadable: Bool = false,
                                  caller: String) throws -> [String] {
        let timer = StoreReadTimer(readMeter, method: caller)
        var rowCount = 0, byteCount = 0
        defer { timer?.finish(rows: rowCount, bytes: byteCount) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_margin_audio_paths")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in bindings.enumerated() { bind(statement, index: Int32(offset + 1), value: value) }
            var paths: [String] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return paths }
                guard step == SQLITE_ROW else {
                    throw SessionKitError.persistenceFailed("step_margin_audio_paths")
                }
                rowCount += 1
                byteCount += Int(sqlite3_column_bytes(statement, 0))
                guard let raw = sqlite3_column_text(statement, 0),
                      let object = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any] else {
                    if skippingUnreadable { continue }
                    throw SessionKitError.persistenceFailed("margin_row_unreadable")
                }
                switch object["audioPath"] {
                case nil, is NSNull: continue
                case let path as String: paths.append(path)
                default:
                    if skippingUnreadable { continue }
                    throw SessionKitError.persistenceFailed("margin_audio_path_unreadable")
                }
            }
        }
    }

    public func saveInterjectionShareRevision(_ revision: InterjectionShareRevision) throws {
        try withTransaction {
            let existing: InterjectionShareRevision? = try loadOptional(
                kind: "interjection_share_revision",
                id: revision.id
            )
            if let existing {
                guard try encoder.encode(existing) == encoder.encode(revision) else {
                    throw SessionKitError.persistenceFailed("interjection_share_revision_immutable_conflict")
                }
                return
            }
            try save(
                kind: "interjection_share_revision",
                id: revision.id,
                sessionId: revision.sessionId,
                itemId: revision.itemId,
                value: revision
            )
        }
    }

    public func loadInterjectionShareRevisions(interjectionId: String) throws -> [InterjectionShareRevision] {
        let revisions: [InterjectionShareRevision] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["interjection_share_revision"]
        )
        return revisions.filter { $0.interjectionId == interjectionId }
    }

    public func importCommentaryLayer(
        _ layer: ImportedCommentaryLayer,
        interjections: [ImportedCommentaryInterjection]
    ) throws -> ImportedCommentaryImportDisposition {
        var disposition: ImportedCommentaryImportDisposition?
        try withTransaction {
            let existing: ImportedCommentaryLayer? = try loadImportedCommentaryLayer(packageDigest: layer.packageDigest)
            if let existing {
                disposition = .duplicate(existingLayerId: existing.id)
                return
            }
            let conflictingLayer: ImportedCommentaryLayer? = try loadOptional(
                kind: "imported_commentary_layer",
                id: layer.id
            )
            guard conflictingLayer == nil else {
                throw SessionKitError.persistenceFailed("imported_commentary_local_id_conflict")
            }
            for interjection in interjections {
                let conflict: ImportedCommentaryInterjection? = try loadOptional(
                    kind: "imported_commentary_interjection",
                    id: interjection.id
                )
                guard conflict == nil else {
                    throw SessionKitError.persistenceFailed("imported_commentary_local_id_conflict")
                }
            }
            try save(
                kind: "imported_commentary_layer",
                id: layer.id,
                sessionId: nil,
                itemId: layer.itemId,
                value: layer
            )
            for interjection in interjections {
                try save(
                    kind: "imported_commentary_interjection",
                    id: interjection.id,
                    sessionId: nil,
                    itemId: layer.itemId,
                    value: interjection
                )
            }
            disposition = .imported(layerId: layer.id, interjectionIds: interjections.map(\.id))
        }
        guard let disposition else {
            throw SessionKitError.persistenceFailed("imported_commentary_disposition_missing")
        }
        return disposition
    }

    public func loadImportedCommentaryLayer(id: String) throws -> ImportedCommentaryLayer? {
        try loadOptional(kind: "imported_commentary_layer", id: id)
    }

    public func loadImportedCommentaryLayer(packageDigest: String) throws -> ImportedCommentaryLayer? {
        let layers: [ImportedCommentaryLayer] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_layer"]
        )
        return layers.first { $0.packageDigest == packageDigest }
    }

    public func loadImportedCommentaryLayers() throws -> [ImportedCommentaryLayer] {
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_layer"]
        )
    }

    public func loadImportedCommentaryLayers(itemId: String) throws -> [ImportedCommentaryLayer] {
        try loadByItem(kind: "imported_commentary_layer", itemId: itemId)
    }

    public func loadImportedCommentaryInterjections(layerId: String) throws -> [ImportedCommentaryInterjection] {
        // Filter before decoding: opening one layer must not materialize every
        // imported recording, transcript and anchor in the Library.
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.layerId') = ? ELSE 1 END ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_interjection", layerId]
        )
    }

    public func saveImportedCommentaryLayer(_ layer: ImportedCommentaryLayer) throws {
        try save(
            kind: "imported_commentary_layer",
            id: layer.id,
            sessionId: nil,
            itemId: layer.itemId,
            value: layer
        )
    }

    /// Saves what a placement pass worked out (the edition it placed against, the placement status and any
    /// map refusal) onto the layer as it is stored now. A pass starts from a copy of the layer and can end
    /// minutes later; saving that whole copy undid anything the listener changed meanwhile, and could bring
    /// back a layer they deleted (#915). Only the pass's own fields are written; a layer that is gone or
    /// deleted is left alone and `false` is returned, so the caller skips that layer's Margins too.
    /// Whether the layer is still stored and not deleted: a layer the listener deleted while a pass ran takes no
    /// part in its result (#915).
    public func isLiveImportedCommentaryLayer(id: String) throws -> Bool {
        try loadImportedCommentaryLayer(id: id).map { $0.deletedAt == nil } ?? false
    }

    /// `records` are the layer's Margins as the pass resolved them; they are saved only when the layer is.
    @discardableResult
    public func savePlacementResult(
        of layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection] = []
    ) throws -> Bool {
        // A transaction, not just the lock: reads on other threads no longer wait for the lock, so they must not see the layer without its Margins.
        try withTransaction {
            guard var stored = try loadImportedCommentaryLayer(id: layer.id), stored.deletedAt == nil else { return false }
            stored.resolvedRecipientEditionSHA256 = layer.resolvedRecipientEditionSHA256
            stored.sourceResolutionStatus = layer.sourceResolutionStatus
            stored.sharedMapRefusalReason = layer.sharedMapRefusalReason
            try saveImportedCommentaryLayer(stored)
            for record in records { try saveImportedCommentaryInterjection(record) }
            return true
        }
    }

    public func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws {
        // The lock, not a transaction: markImportedCommentaryInterjectionHeard calls this inside one.
        try withConnectionLock {
            var interjection = interjection
            let stored: ImportedCommentaryInterjection? = try loadOptional(kind: "imported_commentary_interjection", id: interjection.id)
            // Slow anchor resolution must preserve additive state saved after its snapshot.
            if interjection.firstHeardAt == nil { interjection.firstHeardAt = stored?.firstHeardAt }
            var aliases = stored?.alsoSharedAs ?? []
            for identity in interjection.alsoSharedAs ?? [] where !aliases.contains(identity) { aliases.append(identity) }
            interjection.alsoSharedAs = aliases.isEmpty ? nil : aliases
            let layer = try loadImportedCommentaryLayer(id: interjection.layerId)
            try save(
                kind: "imported_commentary_interjection",
                id: interjection.id,
                sessionId: nil,
                itemId: layer?.itemId,
                value: interjection
            )
        }
    }

    public func markImportedCommentaryInterjectionHeard(id: String, at date: Date) throws -> ImportedCommentaryInterjection? {
        var result: ImportedCommentaryInterjection?
        try withTransaction {
            guard var interjection: ImportedCommentaryInterjection = try loadOptional(
                kind: "imported_commentary_interjection",
                id: id
            ) else { return }
            if interjection.firstHeardAt == nil {
                interjection.firstHeardAt = date
                try saveImportedCommentaryInterjection(interjection)
            }
            result = interjection
        }
        return result
    }

    public func saveTurn(_ turn: ConversationTurn) throws {
        try save(kind: "turn", id: turn.id, sessionId: turn.sessionId, itemId: nil, value: turn)
    }

    public func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        try loadBySession(kind: "turn", sessionId: sessionId)
    }

    /// The id (the turn's own, not the record key `session::turn`) of the session's newest summary turn that has not completed, or nil: what the pending-summary check wants
    /// from `loadTurns(sessionId:)` without decoding every turn of the session (#2506). The same order as that read
    /// (`updated_at`, then `id`), newest first. A turn whose payload isn't valid JSON is skipped here; the whole read
    /// would have refused it.
    public func latestPendingSummaryTurnId(sessionId: String) throws -> String? {
        var found: String?
        try readTexts(
            """
            SELECT json_extract(payload, '$.id') FROM records WHERE kind = 'turn' AND session_id = ? AND json_valid(payload)
              AND json_extract(payload, '$.turnType') = 'interjection_summary'
              AND json_extract(payload, '$.status') IS NOT 'complete'
            ORDER BY updated_at DESC, id DESC LIMIT 1;
            """, [sessionId], name: "latest_pending_summary_turn_id"
        ) { found = $0 }
        return found
    }

    public func saveAIJob(_ job: AIJob) throws {
        try save(kind: "ai_job", id: job.id, sessionId: job.sessionId, itemId: job.itemId, value: job)
    }

    public func loadAIJobs(sessionId: String) throws -> [AIJob] {
        try loadBySession(kind: "ai_job", sessionId: sessionId)
    }

    public func updateAIJob(_ job: AIJob) throws {
        try saveAIJob(job)
    }

    public func saveWatchAudioPackage(_ package: WatchAudioPackage) throws {
        try save(kind: "watch_audio_package", id: package.id, sessionId: package.sessionId, itemId: package.itemId, value: package)
    }

    public func loadWatchAudioPackage(id: String) throws -> WatchAudioPackage? {
        try loadOptional(kind: "watch_audio_package", id: id)
    }

    public func loadWatchAudioPackages(itemId: String) throws -> [WatchAudioPackage] {
        try loadByItem(kind: "watch_audio_package", itemId: itemId)
    }

    public func saveWatchSyncEvent(_ event: WatchSyncEvent) throws {
        try save(kind: "watch_sync_event", id: event.id, sessionId: event.sessionId, itemId: event.itemId, value: event)
    }

    public func loadWatchSyncEvents(sessionId: String) throws -> [WatchSyncEvent] {
        try loadBySession(kind: "watch_sync_event", sessionId: sessionId)
    }

    public func loadWatchSyncEvent(id: String) throws -> WatchSyncEvent? {
        try loadOptional(kind: "watch_sync_event", id: id)
    }

    public func markWatchSyncEventImported(id: String) throws {
        let marker = ImportedWatchSyncEvent(id: id, importedAt: Date())
        try save(kind: "imported_watch_sync_event", id: id, sessionId: nil, itemId: nil, value: marker)
    }

    public func hasImportedWatchSyncEvent(id: String) throws -> Bool {
        let marker: ImportedWatchSyncEvent? = try loadOptional(kind: "imported_watch_sync_event", id: id)
        return marker != nil
    }

    public func saveWatchPackageRequest(_ request: WatchPackageRequestEvent) throws {
        try save(kind: "watch_package_request", id: request.id, sessionId: nil, itemId: request.itemId, value: request)
    }

    public func loadWatchPackageRequests(itemId: String) throws -> [WatchPackageRequestEvent] {
        try loadByItem(kind: "watch_package_request", itemId: itemId)
    }

    public func saveTranscriptTimeline(_ transcript: SourceTranscriptTimeline) throws {
        try save(kind: "source_transcript_timeline", id: transcript.id, sessionId: nil, itemId: transcript.itemId, value: transcript)
    }

    public func loadTranscriptTimeline(id: String) throws -> SourceTranscriptTimeline? {
        try loadOptional(kind: "source_transcript_timeline", id: id)
    }

    /// The newest saved timeline of the item. Only that record is read: a mapped episode's timeline is several MB of
    /// JSON, and decoding every saved version just to keep the last one froze the Item screen (#2073). A record this
    /// build can't decode is quarantined by `query` and leaves the table, so the next pass reads the version before it.
    public func loadTranscriptTimeline(itemId: String) throws -> SourceTranscriptTimeline? {
        while let stamp = try transcriptTimelineStamp(itemId: itemId) {
            let newest: [SourceTranscriptTimeline] = try query("SELECT kind, id, payload \(Self.newestTranscriptTimelineRecord)", [itemId])
            if let found = newest.first { return found }
            guard try transcriptTimelineStamp(itemId: itemId) != stamp else { return nil }
        }
        return nil
    }

    private static let newestTranscriptTimelineRecord =
        "FROM records WHERE kind = 'source_transcript_timeline' AND item_id = ? ORDER BY updated_at DESC, id DESC LIMIT 1;"

    /// The id, save time and byte length of the newest timeline record, read without decoding it (#1696). The engine keeps
    /// the decoded timeline of the item it plays for as long as this doesn't change. A save changes `updated_at`
    /// (and the id when the timeline is replaced), so a stale copy can't outlive the save that replaced it.
    public func transcriptTimelineStamp(itemId: String) throws -> String? {
        var stamp: String?
        try readTexts(
            "SELECT id || '|' || updated_at || '|' || length(CAST(payload AS BLOB)) \(Self.newestTranscriptTimelineRecord)", [itemId], name: "transcript_timeline_stamp"
        ) { stamp = $0 }
        return stamp
    }

    /// Only the chapters and duration of an item's source transcript timeline (#777, #2073). A two-hour episode's
    /// timeline holds thousands of segments and several megabytes of JSON, so the Item screen and the Margins tab read
    /// just this slice: SQLite cuts it out and only the small list is decoded. Even the cut has to parse the whole
    /// payload, so the answer is kept per timeline record and only re-read when the record changes (its id,
    /// `updated_at` or length), not on every refresh. nil when the item has no timeline. A payload that isn't valid JSON
    /// is read the full way, which quarantines it (or throws when it can't), as before.
    public func loadTranscriptTimelineSummary(itemId: String) throws -> TranscriptTimelineSummary? {
        let newest = Self.newestTranscriptTimelineRecord
        let stamp = try transcriptTimelineStamp(itemId: itemId)
        guard let stamp else {
            transcriptSummaryLock.withLock { _ = transcriptSummaryByItem.removeValue(forKey: itemId) }
            return nil
        }
        if let cached = transcriptSummaryLock.withLock({ transcriptSummaryByItem[itemId] }), cached.stamp == stamp { return cached.summary }
        var summaryJSON: String?
        try readTexts(
            """
            SELECT CASE WHEN json_valid(payload) THEN json_object(
                'chapters', CASE WHEN json_type(payload, '$.timeline.chapters') = 'array'
                    THEN json(json_extract(payload, '$.timeline.chapters')) ELSE json('[]') END,
                'durationMs', CASE WHEN json_type(payload, '$.timeline.durationMs') = 'integer'
                    THEN json_extract(payload, '$.timeline.durationMs') END) END \(newest)
            """, [itemId], name: "transcript_timeline_summary"
        ) { summaryJSON = $0 }
        guard let summaryJSON else {
            // Not valid JSON: the full read quarantines it and answers from the version before it, if any.
            guard let timeline = try loadTranscriptTimeline(itemId: itemId)?.timeline else { return nil }
            return TranscriptTimelineSummary(chapters: timeline.chapters, durationMs: timeline.durationMs)
        }
        struct Slice: Decodable { var chapters: [MediaTimelineChapter]?; var durationMs: Int? }
        let slice = summaryJSON.data(using: .utf8).flatMap { try? decoder.decode(Slice.self, from: $0) }
        let summary = TranscriptTimelineSummary(chapters: slice?.chapters ?? [], durationMs: slice?.durationMs)
        transcriptSummaryLock.withLock { transcriptSummaryByItem[itemId] = (stamp: stamp, summary: summary) }
        return summary
    }

    /// The words around each media time, for Margins placed by media time (#2102). Naming the words needs the full
    /// timeline (thousands of segments, several MB of JSON), and every refresh of the Item screen asked for it again, so a
    /// mapped episode with a spoken Margin held the main thread for each tap. The answers are kept per timeline record
    /// (the same stamp as the summary) and the timeline is only decoded for times not answered yet. A time with no
    /// passage is kept as nil so it isn't asked again either.
    public func resolveSourceAnchorContexts(itemId: String, mediaTimesMs: Set<Int>) throws -> [Int: SourceAnchorContext?] {
        guard !mediaTimesMs.isEmpty, let stamp = try transcriptTimelineStamp(itemId: itemId) else {
            anchorContextLock.withLock { _ = anchorContextByItem.removeValue(forKey: itemId) }
            return [:]
        }
        var known: [Int: SourceAnchorContext?] = anchorContextLock.withLock {
            anchorContextByItem[itemId].flatMap { $0.stamp == stamp ? $0.contexts : nil } ?? [:]
        }
        let missing = mediaTimesMs.filter { known.index(forKey: $0) == nil }
        if !missing.isEmpty {
            guard let timeline = try loadTranscriptTimeline(itemId: itemId)?.timeline else { return [:] }
            anchorContextLock.withLock { anchorTimelineDecodeCount += 1 }
            for ms in missing { known[ms] = .some(SourceAnchorContextResolver.resolve(mediaTimeMs: ms, timeline: timeline)) }
            anchorContextLock.withLock { anchorContextByItem[itemId] = (stamp: stamp, contexts: known) }
        }
        return known.filter { mediaTimesMs.contains($0.key) }
    }

    /// How many times `resolveSourceAnchorContexts` decoded a whole timeline. A test reads it to prove a repeat refresh doesn't.
    public var anchorTimelineDecodes: Int { anchorContextLock.withLock { anchorTimelineDecodeCount } }

    /// Only the chapters of an item's source transcript timeline (#777). Empty when there is no timeline.
    public func loadTranscriptTimelineChapters(itemId: String) throws -> [MediaTimelineChapter] {
        try loadTranscriptTimelineSummary(itemId: itemId)?.chapters ?? []
    }

    public func saveAudioAsset(_ asset: AudioAsset) throws {
        try save(kind: "audio_asset", id: asset.id, sessionId: nil, itemId: asset.itemId, value: asset)
    }

    public func loadAudioAssets(itemId: String) throws -> [AudioAsset] {
        try loadByItem(kind: "audio_asset", itemId: itemId)
    }

    public func deleteAudioAsset(id: String) throws {
        try deleteRecord(kind: "audio_asset", id: id)
    }

    public func savePodcastDownload(_ record: PodcastDownloadRecord) throws {
        try save(kind: "podcast_download", id: record.id, sessionId: nil, itemId: record.itemId, value: record)
    }

    public func loadPodcastDownload(itemId: String) throws -> PodcastDownloadRecord? {
        let records: [PodcastDownloadRecord] = try loadByItem(kind: "podcast_download", itemId: itemId)
        return records.last
    }

    public func loadPodcastDownloads() throws -> [PodcastDownloadRecord] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["podcast_download"])
    }

    public func deletePodcastDownload(id: String) throws {
        try deleteRecord(kind: "podcast_download", id: id)
    }

    public func saveCanonicalSource(_ source: CanonicalSourcePackage) throws {
        try withTransaction {
            try deleteRecords(kind: "canonical_source", itemId: source.itemId)
            try save(kind: "canonical_source", id: source.id, sessionId: nil, itemId: source.itemId, value: source)
        }
    }

    public func loadCanonicalSource(itemId: String) throws -> CanonicalSourcePackage? {
        let values: [CanonicalSourcePackage] = try loadByItem(kind: "canonical_source", itemId: itemId)
        return values.last
    }

    public func publishImportedSource(item: Item, canonicalSource: CanonicalSourcePackage?, listeningMap: ListeningMap?, audioAsset: AudioAsset?, ownedAsset: OwnedOfflineAsset) throws {
        try withTransaction {
            try saveItem(item)
            if let canonicalSource {
                try deleteRecords(kind: "canonical_source", itemId: item.id)
                try save(kind: "canonical_source", id: canonicalSource.id, sessionId: nil, itemId: item.id, value: canonicalSource)
            }
            if let listeningMap {
                try deleteRecords(kind: "listening_map", itemId: item.id)
                try save(kind: "listening_map", id: listeningMap.id, sessionId: nil, itemId: item.id, value: listeningMap)
            }
            if let audioAsset { try saveAudioAsset(audioAsset) }
            try saveOwnedOfflineAsset(ownedAsset)
        }
    }

    public func savePreparedAudioManifest(_ manifest: PreparedAudioManifest) throws {
        try save(kind: "prepared_audio_manifest", id: manifest.id, sessionId: nil, itemId: manifest.itemId, value: manifest)
        PreparedAudioChangeSignal.shared.bump() // wakes the playback frontier poll (#2652)
    }

    public func loadPreparedAudioManifest(id: String) throws -> PreparedAudioManifest? {
        try loadOptional(kind: "prepared_audio_manifest", id: id)
    }

    public func loadPreparedAudioManifests(itemId: String) throws -> [PreparedAudioManifest] {
        try loadByItem(kind: "prepared_audio_manifest", itemId: itemId)
    }

    /// Loads every manifest in one query for Library presentation. Callers that
    /// already have the concrete SQLite store can avoid issuing one query per item.
    public func loadPreparedAudioManifests() throws -> [PreparedAudioManifest] {
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;",
            ["prepared_audio_manifest"]
        )
    }

    /// `loadPreparedAudioManifests()` without the chunk lists, in the same order: what the Library rows and the
    /// Preparing Audio lists read (#2506). A finished article's manifest carries a record per chunk (path, checksum,
    /// source range), about 15 KB each at the Library fixture's size; the rows need only the manifest's state and plan and
    /// the chunks' indexes, so SQLite cuts the chunks out and the app copies and decodes a few hundred bytes per manifest.
    /// A payload SQLite can't cut, or that doesn't decode, sends the whole read the full way, which sets the broken
    /// record aside as before.
    public func loadPreparedAudioManifestSummaries() throws -> [PreparedAudioManifestSummary] {
        var rows: [(payload: String, indexes: String)] = []
        var needsFullRead = false
        let timer = StoreReadTimer(readMeter, method: #function)
        defer { timer?.finish(rows: rows.count, bytes: rows.reduce(0) { $0 + $1.payload.utf8.count + $1.indexes.utf8.count }) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            let sql = """
                SELECT CASE WHEN json_valid(payload) THEN json_remove(payload, '$.chunks') END,
                       CASE WHEN json_valid(payload) AND json_type(payload, '$.chunks') = 'array'
                            THEN (SELECT json_group_array(json_extract(chunk.value, '$.index')) FROM json_each(payload, '$.chunks') AS chunk) END
                FROM records WHERE kind = 'prepared_audio_manifest' ORDER BY updated_at, id;
                """
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_manifest_summaries")
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                guard step == SQLITE_ROW else { throw SessionKitError.persistenceFailed("step_manifest_summaries") }
                guard let payload = sqlite3_column_text(statement, 0), let indexes = sqlite3_column_text(statement, 1) else {
                    needsFullRead = true
                    continue
                }
                rows.append((payload: String(cString: payload), indexes: String(cString: indexes)))
            }
        }
        var summaries: [PreparedAudioManifestSummary] = []
        for row in rows {
            guard !needsFullRead, let payload = row.payload.data(using: .utf8), let indexes = row.indexes.data(using: .utf8),
                  let cut = try? decoder.decode(CutManifest.self, from: payload),
                  let chunkIndexes = try? decoder.decode([Int].self, from: indexes) else { needsFullRead = true; break }
            summaries.append(PreparedAudioManifestSummary(
                id: cut.id, itemId: cut.itemId, signature: cut.signature, state: cut.state,
                plannedChunkCount: cut.plannedChunkCount, artifact: cut.artifact, failureCode: cut.failureCode,
                updatedAt: cut.updatedAt, chunkIndexes: chunkIndexes))
        }
        if needsFullRead { return try loadPreparedAudioManifests().map(PreparedAudioManifestSummary.init) }
        return summaries
    }

    /// A manifest's stored fields but its chunks, which `loadPreparedAudioManifestSummaries` cuts out in SQL.
    /// It requires the fields the whole manifest requires but the summary drops, so a record missing one is still set aside.
    private struct CutManifest: Decodable {
        var schemaVersion: String
        var sourcePackageId: String
        var createdAt: Date
        var id: String
        var itemId: String
        var signature: TTSRenderSignature
        var state: PreparedAudioState
        var plannedChunkCount: Int
        var artifact: PreparedAudioArtifact?
        var failureCode: String?
        var updatedAt: Date
    }

    public func deletePreparedAudioManifest(id: String) throws {
        try deleteRecord(kind: "prepared_audio_manifest", id: id)
        PreparedAudioChangeSignal.shared.bump()
    }

    public func saveAudioPreparationJob(_ job: AudioPreparationJob) throws {
        try save(kind: "audio_preparation_job", id: job.id, sessionId: nil, itemId: job.itemId, value: job)
    }

    public func loadAudioPreparationJobs() throws -> [AudioPreparationJob] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["audio_preparation_job"])
    }

    /// One job by id, for a caller that would otherwise decode the whole queue to find it (#2507).
    public func loadAudioPreparationJob(id: String) throws -> AudioPreparationJob? {
        try loadOptional(kind: "audio_preparation_job", id: id)
    }

    /// One item's jobs, in `loadAudioPreparationJobs()`'s order, read through the `item_id` index (#2507).
    public func loadAudioPreparationJobs(itemId: String) throws -> [AudioPreparationJob] {
        try loadByItem(kind: "audio_preparation_job", itemId: itemId)
    }

    public func deleteAudioPreparationJob(id: String) throws { try deleteRecord(kind: "audio_preparation_job", id: id) }

    public func deleteAudioPreparationJobs(ids: [String]) throws {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return }
        try withTransaction {
            for id in uniqueIds {
                try deleteRecord(kind: "audio_preparation_job", id: id)
            }
        }
    }

    public func saveEditionFingerprintSpine(_ spine: EditionFingerprintSpineArtifact) throws {
        try withTransaction {
            try deleteRecords(kind: "edition_fingerprint_spine", itemId: spine.itemId)
            try save(kind: "edition_fingerprint_spine", id: spine.id, sessionId: nil, itemId: spine.itemId, value: spine)
        }
    }

    public func loadEditionFingerprintSpine(itemId: String) throws -> EditionFingerprintSpineArtifact? {
        let values: [EditionFingerprintSpineArtifact] = try loadByItem(kind: "edition_fingerprint_spine", itemId: itemId)
        return values.last
    }

    /// Whether the item has a fingerprint spine, without reading or decoding it (#2506): a spine is megabytes for a long
    /// episode, and a caller that only branches on "is there one" asked `loadEditionFingerprintSpine` for all of it. A
    /// spine this build can't decode counts as present, so a cleanup keeps what it can't read instead of deleting it.
    public func hasEditionFingerprintSpine(itemId: String) throws -> Bool {
        var found = false
        try readTexts("SELECT id FROM records WHERE kind = 'edition_fingerprint_spine' AND item_id = ? LIMIT 1;", [itemId],
                      name: "has_edition_fingerprint_spine") { _ in found = true }
        return found
    }

    public func saveTranscriptPhraseSketch(_ sketch: TranscriptPhraseSketchArtifact) throws {
        try withTransaction {
            try deleteRecords(kind: "transcript_phrase_sketch", itemId: sketch.itemId)
            try save(kind: "transcript_phrase_sketch", id: sketch.id, sessionId: nil, itemId: sketch.itemId, value: sketch)
        }
    }

    public func loadTranscriptPhraseSketch(itemId: String) throws -> TranscriptPhraseSketchArtifact? {
        let values: [TranscriptPhraseSketchArtifact] = try loadByItem(kind: "transcript_phrase_sketch", itemId: itemId)
        return values.last
    }

    /// A Listening Edition revision replaces the item's earlier ones (`ListeningEditionMap.supersedes`): each revision has
    /// its own id, so they piled up and every one travelled in a shared packet (#2118). Existing record kind, no schema change.
    public func savePortableListeningMapProposal(_ proposal: PortableListeningMapProposalArtifact, itemId: String) throws {
        try withTransaction {
            let stored: [PortableListeningMapProposalArtifact] = try loadByItem(kind: "portable_listening_map_proposal", itemId: itemId)
            for superseded in stored where ListeningEditionMap.supersedes(proposal.id, superseded.id) {
                try deleteRecord(kind: "portable_listening_map_proposal", id: superseded.id)
            }
            try save(kind: "portable_listening_map_proposal", id: proposal.id, sessionId: nil, itemId: itemId, value: proposal)
        }
    }

    public func removePortableListeningMapProposals(itemId: String) throws {
        try withTransaction {
            try deleteRecords(kind: "portable_listening_map_proposal", itemId: itemId)
            try deleteRecords(kind: "resolved_listening_map_projection", itemId: itemId)
        }
    }

    public func loadPortableListeningMapProposals(itemId: String) throws -> [PortableListeningMapProposalArtifact] {
        try loadByItem(kind: "portable_listening_map_proposal", itemId: itemId)
    }

    /// The ids of the item's proposals, in `loadPortableListeningMapProposals(itemId:)`'s order, without reading them
    /// (#2506). A proposal carries its whole map, so a caller asking only whether there is one reads this instead.
    public func portableListeningMapProposalIds(itemId: String) throws -> [String] {
        try recordIds(kind: "portable_listening_map_proposal", itemId: itemId, name: #function)
    }

    public func saveResolvedListeningMapProjection(_ projection: ResolvedListeningMapProjection) throws {
        try withTransaction {
            try deleteRecords(kind: "resolved_listening_map_projection", itemId: projection.itemId)
            try save(kind: "resolved_listening_map_projection", id: projection.id, sessionId: nil, itemId: projection.itemId, value: projection)
        }
    }

    /// Stores a community map's proposal and projection together, only if the item still has no
    /// proposal and no projection (#553). Both records or neither: a proposal without its projection
    /// would stop the episode asking again and give Skim nothing. Existing record kinds only.
    /// Returns false, and writes nothing, when the item got a map of its own meanwhile.
    public func saveCommunityMap(
        proposal: PortableListeningMapProposalArtifact,
        projection: ResolvedListeningMapProjection
    ) throws -> Bool {
        try withTransaction {
            guard try portableListeningMapProposalIds(itemId: projection.itemId).isEmpty,
                  try loadResolvedListeningMapProjection(itemId: projection.itemId) == nil,
                  // A friend's map not placed yet (its audio may still be downloading) comes first.
                  try !loadImportedCommentaryLayers(itemId: projection.itemId).contains(where: \.holdsListeningMap)
            else { return false }
            try savePortableListeningMapProposal(proposal, itemId: projection.itemId)
            try saveResolvedListeningMapProjection(projection)
            return true
        }
    }

    public func removeCommunityMap(itemId: String) throws {
        try withTransaction {
            for proposal in try loadPortableListeningMapProposals(itemId: itemId)
            where CommunityMapConverter.isCommunityProposal(id: proposal.id) {
                try deleteRecord(kind: "portable_listening_map_proposal", id: proposal.id)
            }
            if let projection = try loadResolvedListeningMapProjection(itemId: itemId),
               CommunityMapConverter.isCommunityProjection(projection) {
                try deleteRecords(kind: "resolved_listening_map_projection", itemId: itemId)
            }
        }
    }

    public func loadResolvedListeningMapProjection(itemId: String) throws -> ResolvedListeningMapProjection? {
        let values: [ResolvedListeningMapProjection] = try loadByItem(kind: "resolved_listening_map_projection", itemId: itemId)
        return values.last
    }

    public func saveEpisodeMapPreparationJob(_ job: EpisodeMapPreparationJob) throws {
        try save(kind: "episode_map_preparation_job", id: job.id, sessionId: nil, itemId: job.itemId, value: job)
    }

    public func loadEpisodeMapPreparationJobs() throws -> [EpisodeMapPreparationJob] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["episode_map_preparation_job"])
    }

    /// One job by id, for a caller that would otherwise decode every episode-map job to find it (#2507).
    public func loadEpisodeMapPreparationJob(id: String) throws -> EpisodeMapPreparationJob? {
        try loadOptional(kind: "episode_map_preparation_job", id: id)
    }

    /// One item's jobs, in `loadEpisodeMapPreparationJobs()`'s order, read through the `item_id` index (#2507).
    public func loadEpisodeMapPreparationJobs(itemId: String) throws -> [EpisodeMapPreparationJob] {
        try loadByItem(kind: "episode_map_preparation_job", itemId: itemId)
    }

    public func deleteEpisodeMapPreparationJob(id: String) throws {
        try deleteRecord(kind: "episode_map_preparation_job", id: id)
    }

    public func saveOfflineStorageBudget(_ budget: OfflineStorageBudget) throws {
        try save(kind: "offline_storage_budget", id: "default", sessionId: nil, itemId: nil, value: budget)
    }

    public func loadOfflineStorageBudget() throws -> OfflineStorageBudget {
        try loadOptional(kind: "offline_storage_budget", id: "default") ?? OfflineStorageBudget()
    }

    public func saveOwnedOfflineAsset(_ asset: OwnedOfflineAsset) throws {
        try save(kind: "owned_offline_asset", id: asset.id, sessionId: nil, itemId: asset.itemId, value: asset)
    }

    public func loadOwnedOfflineAssets() throws -> [OwnedOfflineAsset] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["owned_offline_asset"])
    }

    /// One item's owned offline assets, in `loadOwnedOfflineAssets()`'s order, read through the `item_id` index: for a
    /// caller that already has the item and would otherwise decode every ledger row to filter by `itemId` (#2507).
    public func loadOwnedOfflineAssets(itemId: String) throws -> [OwnedOfflineAsset] {
        try loadByItem(kind: "owned_offline_asset", itemId: itemId)
    }

    public func deleteOwnedOfflineAsset(id: String) throws { try deleteRecord(kind: "owned_offline_asset", id: id) }

    @discardableResult
    public func updateOwnedOfflineAsset(id: String, _ change: (inout OwnedOfflineAsset) -> Void) throws -> OwnedOfflineAsset? {
        try withTransaction {
            guard var asset: OwnedOfflineAsset = try loadOptional(kind: "owned_offline_asset", id: id) else { return nil }
            change(&asset)
            try saveOwnedOfflineAsset(asset)
            return asset
        }
    }

    @discardableResult
    public func deleteOwnedOfflineAsset(id: String, if shouldDelete: (OwnedOfflineAsset) -> Bool) throws -> Bool {
        try withTransaction {
            guard let asset: OwnedOfflineAsset = try loadOptional(kind: "owned_offline_asset", id: id),
                  shouldDelete(asset) else { return false }
            try deleteOwnedOfflineAsset(id: id)
            return true
        }
    }

    public func saveOfflineStorageReservation(_ reservation: OfflineStorageReservation) throws {
        try save(kind: "offline_storage_reservation", id: reservation.id, sessionId: nil, itemId: nil, value: reservation)
    }

    public func loadOfflineStorageReservations() throws -> [OfflineStorageReservation] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["offline_storage_reservation"])
    }

    /// One reservation by id, for a caller that already knows which one it wants and would otherwise decode every
    /// reservation to find it (#2507).
    public func loadOfflineStorageReservation(id: String) throws -> OfflineStorageReservation? {
        try loadOptional(kind: "offline_storage_reservation", id: id)
    }

    public func deleteOfflineStorageReservation(id: String) throws { try deleteRecord(kind: "offline_storage_reservation", id: id) }

    public func saveFeedSubscription(_ subscription: FeedSubscription) throws {
        try save(kind: "feed_subscription", id: subscription.id, sessionId: nil, itemId: nil, value: subscription)
    }

    /// Collections are their own record kind with no item_id, so Build 29 (which reads every
    /// record by an explicit kind) never sees them, and deleting an item never deletes one (#489).
    public func saveItemCollection(_ collection: ItemCollection) throws {
        try save(kind: "item_collection", id: collection.id, sessionId: nil, itemId: nil, value: collection)
    }

    /// Oldest first, so the listener's collections keep a stable order.
    public func loadItemCollections() throws -> [ItemCollection] {
        let collections: [ItemCollection] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY id;",
            ["item_collection"]
        )
        return collections.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func deleteItemCollection(id: String) throws {
        try deleteRecord(kind: "item_collection", id: id)
    }

    public func loadFeedSubscriptions() throws -> [FeedSubscription] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["feed_subscription"])
    }

    public func deleteFeedSubscription(id: String) throws {
        let entries: [FeedEntry] = try loadFeedEntries(subscriptionId: id)
        try withTransaction {
            for entry in entries where entry.state != .imported { try deleteRecord(kind: "feed_entry", id: entry.id) }
            try deleteRecord(kind: "feed_subscription", id: id)
        }
    }

    public func saveFeedEntry(_ entry: FeedEntry) throws {
        try save(kind: "feed_entry", id: entry.id, sessionId: nil, itemId: nil, value: entry)
    }

    /// With a `subscriptionId`, SQLite keeps only that source's rows, so the others are neither copied out nor decoded
    /// (#2506); each entry can carry the article's full body. A payload that is not valid JSON gives NULL and matches
    /// nothing, as it did when the filter ran after a decode that would have quarantined it.
    public func loadFeedEntries(subscriptionId: String?) throws -> [FeedEntry] {
        guard let subscriptionId else {
            return try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["feed_entry"])
        }
        return try query("""
            SELECT kind, id, payload FROM records
            WHERE kind = ? AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.subscriptionId') END = ?
            ORDER BY updated_at DESC, id;
            """, ["feed_entry", subscriptionId], caller: "loadFeedEntries(subscriptionId:)")
    }

    public func deleteFeedEntry(id: String) throws { try deleteRecord(kind: "feed_entry", id: id) }

    public func saveFeedRefreshState(_ state: FeedRefreshState) throws {
        try save(kind: "feed_refresh_state", id: state.subscriptionId, sessionId: nil, itemId: nil, value: state)
    }

    public func loadFeedRefreshState(subscriptionId: String) throws -> FeedRefreshState? {
        try loadOptional(kind: "feed_refresh_state", id: subscriptionId)
    }

    public func saveSourceSuggestionDecision(_ decision: SourceSuggestionDecision) throws {
        try save(kind: "source_suggestion_decision", id: decision.sourceId, sessionId: nil, itemId: nil, value: decision)
    }

    public func loadSourceSuggestionDecision(sourceId: String) throws -> SourceSuggestionDecision? {
        try loadOptional(kind: "source_suggestion_decision", id: sourceId)
    }

    public func seed(item: Item) throws {
        try saveItem(item)
    }

    public func seed(map: ListeningMap) throws {
        try saveListeningMap(map)
    }

    public func seed(interjection: Interjection) throws {
        try saveInterjection(interjection)
    }

    public func seed(turn: ConversationTurn) throws {
        try saveTurn(turn)
    }

    public func listItems(includeDeleted: Bool = false) throws -> [Item] {
        let items: [Item] = try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["item"])
        return includeDeleted ? items : items.filter { $0.deletedAt == nil }
    }

    /// The items whose `externalReference` is exactly `address`, deleted ones included. SQLite looks for the address's
    /// stored spelling in each payload as plain text first, so only the few items that name it are decoded; the
    /// reference is compared again after decoding, so a longer address that contains this one never matches.
    public func listItems(withExternalReference address: String) throws -> [Item] {
        guard let needle = (try? encoder.encode(address)).flatMap({ String(data: $0, encoding: .utf8) }) else { return [] }
        let items: [Item] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? AND instr(payload, ?) > 0 ORDER BY updated_at DESC, id;",
            ["item", needle]
        )
        return items.filter { $0.externalReference == address }
    }

    /// Whether `id` is an item in the Library that is not in the trash: the yes or no a caller wants when it would
    /// otherwise read every item to look for one id (#2506). Reads and decodes that one row.
    public func hasLiveItem(id: String) throws -> Bool {
        let items: [Item] = try query("SELECT kind, id, payload FROM records WHERE kind = ? AND id = ?;", ["item", id])
        return items.first.map { $0.deletedAt == nil } ?? false
    }

    /// The Library list's read (#2102): every item in `listItems`' order, without its `text` or `documentStructure`.
    /// SQLite cuts those two out of each payload, so the several MB of an article or book are never copied or decoded.
    /// The text's length is counted in Unicode scalars, which is how SQLite counts; it differs from Swift's character
    /// count only for text with combining marks or joined emoji, and only feeds the listening-time estimate. A payload
    /// that can't be cut or decoded sends the whole read the full way, which sets the broken record aside as before.
    /// The cut is kept beside each item (`ItemDerivedRecords.swift`), so a later read of an item that hasn't changed
    /// reads that small record and leaves the payload alone (#2506).
    public func listItemSummaries(includeDeleted: Bool = false) throws -> [LibraryItemSummary] {
        try itemSummaries(onlyId: nil, includeDeleted: includeDeleted, method: #function)
    }

    /// One item's summary, trashed or not, or nil when `id` is not an item: for a caller that has an id and needs only
    /// what the Library row knows, not the item's text (#2506). The same cut of the payload as `listItemSummaries`.
    public func loadItemSummary(id: String) throws -> LibraryItemSummary? {
        try itemSummaries(onlyId: id, includeDeleted: true, method: #function).first
    }

    private func itemSummaries(onlyId: String?, includeDeleted: Bool, method: String) throws -> [LibraryItemSummary] {
        guard let slices = try itemSlices(onlyId: onlyId, method: method) else {
            return try listItems(includeDeleted: includeDeleted).filter { onlyId == nil || $0.id == onlyId }.map(LibraryItemSummary.init)
        }
        let summaries = librarySummaries(from: slices)
        return includeDeleted ? summaries : summaries.filter { $0.deletedAt == nil }
    }

    /// Recently Deleted as the Library shows it: the trashed items' summaries, most recently deleted first, without
    /// their text (#2506). The same order and members as `listDeletedItems()`.
    public func listDeletedItemSummaries() throws -> [LibraryItemSummary] {
        try itemSummaries(onlyId: nil, includeDeleted: true, method: #function)
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func listDeletedItems() throws -> [Item] {
        try listItems(includeDeleted: true)
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func moveItemToTrash(id: String, at date: Date = Date()) throws {
        var item = try loadItem(id: id)
        item.deletedAt = date
        try saveItem(item)
    }

    public func restoreItem(id: String) throws {
        var item = try loadItem(id: id)
        item.deletedAt = nil
        try saveItem(item)
    }

    private static func quarantinedJSON(_ path: String) -> String {
        "CASE WHEN json_valid(payload) THEN json_extract(payload, '\(path)') END"
    }

    /// A `quarantined_records` row (`?1` is the item id) that belongs to the item: the item itself, or any row
    /// whose payload names it. The payload is read as JSON, not decoded, because these are the rows this build
    /// can't decode. A payload that isn't JSON can't be tied to an item, so it isn't matched. Turns carry only
    /// a session id and imported Margins only a layer id, so they go with the item's sessions and layers,
    /// live or quarantined.
    /// The kinds whose live save path files the row under the item named in its payload (`item_id`). A kind
    /// that deliberately outlives its item, such as `community_map_upload`, is not here (#1466).
    private static let itemScopedQuarantineKinds = """
        'item', 'listening_map', 'session', 'interjection', 'ai_job', 'interjection_share_revision', \
        'imported_commentary_layer', 'canonical_source', 'audio_asset', 'source_transcript_timeline', \
        'podcast_download', 'owned_offline_asset', 'episode_map_preparation_job', 'audio_preparation_job', \
        'prepared_audio_manifest', 'edition_fingerprint_spine', 'transcript_phrase_sketch', \
        'resolved_listening_map_projection', 'watch_audio_package', 'watch_sync_event', 'watch_package_request'
        """

    private static let quarantinedRowBelongsToItem = """
        (kind = 'item' AND id = ?1)
        OR (kind = 'publisher_audio' AND id = ?1)
        OR (kind IN (\(itemScopedQuarantineKinds)) AND \(quarantinedJSON("$.itemId")) = ?1)
        OR (kind = 'structured_document' AND substr(id, 1, length(?1) + 2) = ?1 || '#v')
        OR (kind = 'turn' AND \(quarantinedJSON("$.sessionId")) IN (\(quarantinedSessionIdsOfItem)))
        OR (kind = 'imported_commentary_interjection' AND \(quarantinedJSON("$.layerId")) IN (\(quarantinedLayerIdsOfItem)))
        """

    private static let quarantinedSessionIdsOfItem = """
        SELECT id FROM records WHERE kind = 'session' AND item_id = ?1
        UNION SELECT id FROM quarantined_records WHERE kind = 'session' AND \(quarantinedJSON("$.itemId")) = ?1
        """

    private static let quarantinedLayerIdsOfItem = """
        SELECT id FROM records WHERE kind = 'imported_commentary_layer' AND item_id = ?1
        UNION SELECT id FROM quarantined_records WHERE kind = 'imported_commentary_layer' AND \(quarantinedJSON("$.itemId")) = ?1
        """

    /// Takes the item's quarantined rows with it (#1466). Turns and imported Margins go first, as their own
    /// statements, while the sessions and layers they are tied through are still there to be found.
    private func deleteQuarantinedRows(ofItem id: String) throws {
        // Nearly every library has nothing set aside: skip the scans.
        guard try quarantinedRecordCount() > 0 else { return }
        try runDelete(
            "DELETE FROM quarantined_records WHERE kind = 'turn' AND \(Self.quarantinedJSON("$.sessionId")) IN (\(Self.quarantinedSessionIdsOfItem));",
            prepareError: "prepare_delete_item_quarantined_turns", stepError: "step_delete_item_quarantined_turns", ids: [id])
        try runDelete(
            "DELETE FROM quarantined_records WHERE kind = 'imported_commentary_interjection' AND \(Self.quarantinedJSON("$.layerId")) IN (\(Self.quarantinedLayerIdsOfItem));",
            prepareError: "prepare_delete_item_quarantined_imports", stepError: "step_delete_item_quarantined_imports", ids: [id])
        try runDelete(
            "DELETE FROM quarantined_records WHERE (kind = 'item' AND id = ?1) OR (kind = 'publisher_audio' AND id = ?1) OR (kind IN (\(Self.itemScopedQuarantineKinds)) AND \(Self.quarantinedJSON("$.itemId")) = ?1) OR (kind = 'structured_document' AND substr(id, 1, length(?1) + 2) = ?1 || '#v');",
            prepareError: "prepare_delete_item_quarantined", stepError: "step_delete_item_quarantined", ids: [id])
    }

    public func deleteItem(id: String) throws {
        defer { noteItemWritten(id) }
        // Turns are saved with a session id and no item id, so they are found through the item's
        // session rows. They go first, as their own statement: a single DELETE that also removed the
        // session rows could evaluate its subquery after those rows were gone and keep the turns
        // (SQLite 3.37 on Linux did, #1219). One transaction, so a failure leaves the item whole.
        try withTransaction {
            try withConnectionLock {
                // The item's quarantined sessions count too: their live turns go, then the quarantined rows (#1466).
                try runDelete(
                    """
                    DELETE FROM records
                    WHERE kind = 'turn' AND session_id IN (\(Self.quarantinedSessionIdsOfItem));
                    """, prepareError: "prepare_delete_item_turns", stepError: "step_delete_item_turns", ids: [id])
                try deleteQuarantinedRows(ofItem: id)
                try runDelete(
                    """
                    DELETE FROM records
                    WHERE item_id = ?
                       OR (kind = 'item' AND id = ?);
                    """, prepareError: "prepare_delete_item", stepError: "step_delete_item", ids: [id, id])
            }
        }
    }

    private func runDelete(_ sql: String, prepareError: String, stepError: String, ids: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed(prepareError)
        }
        defer { if statement != nil { sqlite3_finalize(statement) } }
        for (offset, value) in ids.enumerated() {
            bind(statement, index: Int32(offset + 1), value: value)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed(stepError)
        }
    }

    /// Permanently removes several item graphs as one database operation. Callers
    /// validate the trash boundary before invoking this method; the transaction
    /// prevents a bulk-empty action from leaving only part of the selection behind.
    public func deleteItems(ids: [String]) throws {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard !uniqueIDs.isEmpty else { return }
        try withTransaction {
            for id in uniqueIDs {
                try deleteItem(id: id)
            }
        }
    }

    private func deleteRecords(kind: String, itemId: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE kind = ? AND item_id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_delete_records")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: itemId)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_delete_records")
            }
        }
    }

    private func deleteRecord(kind: String, id: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE kind = ? AND id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_delete_record")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_delete_record")
            }
        }
    }

    func save<T: Encodable>(kind: String, id: String, sessionId: String?, itemId: String?, value: T) throws {
        try withConnectionLock {
            let data = try encoder.encode(value)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw SessionKitError.persistenceFailed("json_encoding")
            }
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO records(kind, id, session_id, item_id, payload)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(kind, id) DO UPDATE SET
                session_id = excluded.session_id,
                item_id = excluded.item_id,
                payload = excluded.payload,
                updated_at = CURRENT_TIMESTAMP;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_save")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: storageID(kind: kind, id: id, sessionId: sessionId))
            bind(statement, index: 3, value: sessionId)
            bind(statement, index: 4, value: itemId)
            bind(statement, index: 5, value: payload)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_save:\(sqlite3_extended_errcode(db)):\(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private func load<T: Decodable>(kind: String, id: String, caller: String = #function) throws -> T {
        guard let value: T = try loadOptional(kind: kind, id: id, caller: caller) else {
            throw SessionKitError.missingFixture("\(kind):\(id)")
        }
        return value
    }

    private func loadOptional<T: Decodable>(kind: String, id: String, caller: String = #function) throws -> T? {
        let values: [T] = try query("SELECT kind, id, payload FROM records WHERE kind = ? AND id = ?;", [kind, id], caller: caller)
        return values.first
    }

    private func loadBySession<T: Decodable>(kind: String, sessionId: String, caller: String = #function) throws -> [T] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? AND session_id = ? ORDER BY updated_at, id;", [kind, sessionId], caller: caller)
    }

    /// The ids of an item's records of one kind, in `loadByItem`'s order. Only the id column is read (#2506).
    private func recordIds(kind: String, itemId: String, name: String) throws -> [String] {
        var ids: [String] = []
        try readTexts("SELECT id FROM records WHERE kind = ? AND item_id = ? ORDER BY updated_at, id;",
                      [kind, itemId], name: name) { ids.append($0) }
        return ids
    }

    private func loadByItem<T: Decodable>(kind: String, itemId: String, caller: String = #function) throws -> [T] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? AND item_id = ? ORDER BY updated_at, id;", [kind, itemId], caller: caller)
    }

    /// Rows are copied out while the connection lock is held and decoded after it is released, so a small read or write
    /// on another thread (the main thread's, usually) never waits for a big background read to finish decoding (#2103).
    /// A caller that already holds the lock keeps holding it; the gain is for callers that don't.
    ///
    /// `caller` names the public method the read is metered under (#2258); the helpers above pass it down.
    private func query<T: Decodable>(_ sql: String, _ values: [String], caller: String = #function) throws -> [T] {
        let timer = StoreReadTimer(readMeter, method: caller)
        var rows: [(kind: String, id: String, payload: String)] = []
        defer { timer?.finish(rows: rows.count, bytes: rows.reduce(0) { $0 + $1.payload.utf8.count }) }
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_query")
            }
            defer { if statement != nil { sqlite3_finalize(statement) } }
            for (index, value) in values.enumerated() {
                bind(statement, index: Int32(index + 1), value: value)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawKind = sqlite3_column_text(statement, 0),
                      let rawID = sqlite3_column_text(statement, 1),
                      let raw = sqlite3_column_text(statement, 2) else { continue }
                rows.append((kind: String(cString: rawKind), id: String(cString: rawID), payload: String(cString: raw)))
            }
            sqlite3_finalize(statement)
            statement = nil
        }
        var decoded: [T] = []
        var corrupt: [(kind: String, id: String, payload: String, error: String)] = []
        for row in rows {
            guard let data = row.payload.data(using: .utf8) else { continue }
            do {
                decoded.append(try decoder.decode(T.self, from: data))
            } catch {
                corrupt.append((kind: row.kind, id: row.id, payload: row.payload, error: String(describing: error)))
            }
        }
        if !corrupt.isEmpty {
            try withTransaction {
                for record in corrupt {
                    // The lock was released while decoding, so the row may have been rewritten since it was read.
                    // Only a row that still holds the bytes that failed is set aside.
                    guard try storedPayload(kind: record.kind, id: record.id) == record.payload else { continue }
                    try quarantine(kind: record.kind, id: record.id, payload: record.payload, error: record.error)
                }
            }
        }
        return decoded
    }

    private func storedPayload(kind: String, id: String) throws -> String? {
        var payload: String?
        try readTexts("SELECT payload FROM records WHERE kind = ? AND id = ?;", [kind, id], name: "stored_payload") { payload = $0 }
        return payload
    }

    private static func isNewerSession(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        return lhsDate == rhsDate ? lhs.id > rhs.id : lhsDate > rhsDate
    }

    private func migrateSessionTimestamps() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, payload, updated_at FROM records WHERE kind = 'session';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_session_timestamp_migration")
        }
        var updates: [(id: String, payload: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0),
                  let rawPayload = sqlite3_column_text(statement, 1),
                  let rawUpdatedAt = sqlite3_column_text(statement, 2),
                  let data = String(cString: rawPayload).data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let id = String(cString: rawID)
            let timestamp = Self.iso8601Timestamp(fromSQLite: String(cString: rawUpdatedAt))
            if object["createdAt"] == nil { object["createdAt"] = timestamp }
            if object["updatedAt"] == nil { object["updatedAt"] = timestamp }
            if object["completedAt"] == nil {
                object["completedAt"] = object["status"] as? String == "finished" ? timestamp : NSNull()
            }
            guard let migrated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let payload = String(data: migrated, encoding: .utf8) else { continue }
            updates.append((id, payload))
        }
        sqlite3_finalize(statement)
        statement = nil

        try withTransaction {
            for update in updates {
                var updateStatement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    db,
                    "UPDATE records SET payload = ? WHERE kind = 'session' AND id = ?;",
                    -1,
                    &updateStatement,
                    nil
                ) == SQLITE_OK else {
                    throw SessionKitError.persistenceFailed("prepare_session_timestamp_update")
                }
                bind(updateStatement, index: 1, value: update.payload)
                bind(updateStatement, index: 2, value: update.id)
                let result = sqlite3_step(updateStatement)
                sqlite3_finalize(updateStatement)
                guard result == SQLITE_DONE else {
                    throw SessionKitError.persistenceFailed("step_session_timestamp_update")
                }
            }
        }
    }

    /// Turns, interjections, and AI jobs use IDs that are intentionally local to a
    /// listening session (for example, `turn-response-001`). The records table has
    /// a `(kind, id)` primary key, so storing those logical IDs directly allowed a
    /// later session to move and overwrite an earlier session's record. Keep the
    /// payload IDs unchanged while making only the internal SQLite key session-scoped.
    private func migrateSessionScopedRecordKeys() throws {
        for kind in Self.sessionScopedRecordKinds.sorted() {
            var statement: OpaquePointer?
            let sql = """
            UPDATE records
            SET id = session_id || '::' || id
            WHERE kind = ?
              AND session_id IS NOT NULL
              AND id NOT LIKE session_id || '::%';
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_session_scoped_key_migration")
            }
            bind(statement, index: 1, value: kind)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_session_scoped_key_migration")
            }
        }
    }

    private func storageID(kind: String, id: String, sessionId: String?) -> String {
        guard Self.sessionScopedRecordKinds.contains(kind), let sessionId else { return id }
        return "\(sessionId)::\(id)"
    }

    private static func iso8601Timestamp(fromSQLite value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: value) else { return value }
        return ISO8601DateFormatter().string(from: date)
    }

    public static func schemaVersion(atPath path: String) -> Int? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = 'schema_version';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return Int(String(cString: raw))
    }

    private func quarantine(kind: String, id: String, payload: String, error: String) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO quarantined_records(kind, id, payload, decode_error)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(kind, id) DO UPDATE SET
            payload = excluded.payload,
            decode_error = excluded.decode_error,
            quarantined_at = CURRENT_TIMESTAMP;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: kind)
        bind(statement, index: 2, value: id)
        bind(statement, index: 3, value: payload)
        bind(statement, index: 4, value: String(error.prefix(2_000)))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine")
        }
        try deleteQuarantinedSource(kind: kind, id: id)
    }

    private func deleteQuarantinedSource(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM records WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine_delete")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: kind)
        bind(statement, index: 2, value: id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine_delete")
        }
    }

    /// Runs `operation` in one transaction. A call made inside another joins the open transaction, because
    /// SQLite can't nest them: a read inside `updateOwnedOfflineAsset` that meets a malformed row quarantines
    /// it in the update's transaction (#529 audit). If anything in the outer transaction throws, all of it
    /// rolls back, the quarantine included, and the next read quarantines the row again.
    public func withSessionTransaction<T>(_ operation: () throws -> T) throws -> T {
        try withTransaction(operation)
    }

    func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try withConnectionLock {
            guard transactionDepth == 0 else { return try operation() }
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            transactionDepth += 1
            transactionOwnerLock.withLock { transactionOwner = pthread_self() }
            defer {
                transactionOwnerLock.withLock { transactionOwner = nil }
                transactionDepth -= 1
                let written = itemsWrittenInTransaction
                itemsWrittenInTransaction = []
                for id in written { bumpItemRevision(id) }
            }
            do {
                let result = try operation()
                try execute("COMMIT;")
                return result
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func metadataValue(forKey key: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_metadata_read")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func setMetadataValue(_ value: String, forKey key: String) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_metadata_write")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        bind(statement, index: 2, value: value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_metadata_write")
        }
    }

    private func execute(_ sql: String) throws {
        try withConnectionLock {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw SessionKitError.persistenceFailed(message)
            }
        }
    }

    /// Runs a read on a connection of its own, so it waits for neither the writer's lock nor another read (#2103).
    /// WAL gives such a connection the last committed state, as of when each statement starts. A thread with a
    /// transaction open reads on the writer's connection instead, to see what it has written and not yet committed.
    func withReadConnection<T>(_ operation: (OpaquePointer?) throws -> T) rethrows -> T {
        if let readConnections, !currentThreadHasTransactionOpen(), let reader = readConnections.checkOut() {
            defer { readConnections.checkIn(reader) }
            return try operation(reader)
        }
        return try withConnectionLock { try operation(db) }
    }

    private func currentThreadHasTransactionOpen() -> Bool {
        transactionOwnerLock.withLock { transactionOwner.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
    }

    func withConnectionLock<T>(_ operation: () throws -> T) rethrows -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return try operation()
    }

    func bind(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }
}

/// Read-only connections to one WAL database, checked out one reader at a time and opened as readers need them (#2103).
/// A connection is never shared by two readers, so a long read can't make another reader wait behind it.
///
/// Only `idleLimit` connections stay open between reads; a burst opens up to `limit` and the rest close as they come
/// back. A WAL reader holds the database, `-wal` and `-shm` files, and iOS gives an app 256 descriptors, so six idle
/// readers on every store a test run leaves alive added up to EMFILE (#2818).
final class ReadConnectionPool: @unchecked Sendable {
    private let path: String
    private let limit: Int
    private let idleLimit: Int
    private let condition = NSCondition()
    private var idle: [OpaquePointer] = []
    /// Connections open or being opened, idle or checked out.
    private var openCount = 0
    private var isClosed = false

    init(path: String, limit: Int, idleLimit: Int = 2) {
        self.path = path
        self.limit = limit
        self.idleLimit = max(0, min(idleLimit, limit))
    }

    /// Connections open now, idle or checked out.
    var openConnectionCount: Int {
        condition.lock(); defer { condition.unlock() }
        return openCount
    }

    /// A connection to read on, or nil when none can be opened: the caller then reads on the writer's connection.
    /// Waits only when `limit` connections are all in use.
    func checkOut() -> OpaquePointer? {
        condition.lock()
        while true {
            if isClosed { condition.unlock(); return nil }
            if let connection = idle.popLast() { condition.unlock(); return connection }
            if openCount < limit {
                openCount += 1
                condition.unlock()
                if let connection = open() { return connection }
                condition.lock()
                openCount -= 1
                condition.signal()
                condition.unlock()
                return nil
            }
            condition.wait()
        }
    }

    func checkIn(_ connection: OpaquePointer) {
        condition.lock()
        if isClosed || idle.count >= idleLimit {
            sqlite3_close(connection)
            openCount -= 1
            condition.signal()
        } else {
            idle.append(connection)
            condition.signal()
        }
        condition.unlock()
    }

    /// Closes the idle connections. One still checked out is closed when it comes back.
    func close() {
        condition.lock()
        isClosed = true
        for connection in idle { sqlite3_close(connection) }
        openCount -= idle.count
        idle = []
        condition.broadcast()
        condition.unlock()
    }

    private func open() -> OpaquePointer? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(connection)
            return nil
        }
        sqlite3_busy_timeout(connection, 1_000)
        // A reader that tried to write would take the writer's lock; make it fail instead.
        sqlite3_exec(connection, "PRAGMA query_only=ON;", nil, nil, nil)
        return connection
    }
}

/// What `SQLiteSessionStore.marginNoteChanges(after:)` found.
public struct MarginNoteChanges: Equatable, Sendable {
    public var sessionIds: Set<String>
    /// Pass this as `after` next time; everything up to it has been seen.
    public var settledThrough: String

    public init(sessionIds: Set<String>, settledThrough: String) {
        self.sessionIds = sessionIds
        self.settledThrough = settledThrough
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct ImportedWatchSyncEvent: Codable {
    var id: String
    var importedAt: Date
}

/// The counts the engine publishes on every playback tick, made in SQLite from the session index so no payload is
/// copied or decoded (#2509). They match `loadInterjections(sessionId:)` and `loadAIJobs(sessionId:)` filtered the
/// same way; a row that isn't valid JSON is left out, as those reads leave out a row they can't decode.
extension SQLiteSessionStore: SessionRecordCounting {
    public func activeInterjectionCount(sessionId: String) throws -> Int {
        try sessionRecordCount(
            "kind = 'interjection' AND json_extract(payload, '$.status') = 'active'", sessionId: sessionId,
            name: "activeInterjectionCount")
    }

    public func unfinishedAIJobCount(sessionId: String) throws -> Int {
        try sessionRecordCount(
            "kind = 'ai_job' AND IFNULL(json_extract(payload, '$.status'), '') != 'complete'", sessionId: sessionId,
            name: "unfinishedAIJobCount")
    }

    private func sessionRecordCount(_ condition: String, sessionId: String, name: String) throws -> Int {
        var count = 0
        try readTexts(
            "SELECT count(*) FROM records WHERE session_id = ? AND json_valid(payload) AND \(condition);",
            [sessionId], name: name
        ) { count = Int($0) ?? 0 }
        return count
    }
}

extension SQLiteSessionStore: InterjectionByIdReading {
    /// A Margin row is keyed by its session and id (`storageID`), so this is one primary-key read.
    public func loadInterjection(id: String, sessionId: String) throws -> Interjection? {
        let stored: Interjection? = try loadOptional(kind: "interjection", id: storageID(kind: "interjection", id: id, sessionId: sessionId))
        return stored.flatMap { $0.id == id && $0.sessionId == sessionId ? $0 : nil }
    }
}

extension SQLiteSessionStore: ItemRevisionReading {}
extension SQLiteSessionStore: ItemAddressLookup {}

/// The pictures, embeds and links an imported Substack page carries (#2032), in the existing records table as kind
/// "source_elements", one row per item. No table or column changes and schema_version stays 5: an older build
/// selects records by kind and never reads this one, and deleting the item removes the row with it.
extension SQLiteSessionStore: SourceElementsRepository {
    static let sourceElementsKind = "source_elements"

    public func saveSourceElements(_ record: SourceElementsRecord, itemId: String) throws {
        try save(kind: Self.sourceElementsKind, id: "\(itemId)#elements", sessionId: nil, itemId: itemId, value: record)
    }

    public func loadSourceElements(itemId: String) throws -> SourceElementsRecord? {
        let records: [SourceElementsRecord] = try loadByItem(kind: Self.sourceElementsKind, itemId: itemId)
        return records.first
    }
}

/// I13 documents live in the existing records table as kind
/// "structured_document", one row per item and extraction version. No table or
/// column changes, and schema_version stays 5: Build 29 selects records by kind
/// and never reads this one, and deleting the item removes its rows.
extension SQLiteSessionStore: StructuredDocumentRepository {
    static let structuredDocumentKind = "structured_document"

    public func saveStructuredDocument(_ document: StructuredDocument, itemId: String) throws {
        try save(
            kind: Self.structuredDocumentKind,
            id: "\(itemId)#v\(document.extraction.version)",
            sessionId: nil,
            itemId: itemId,
            value: document
        )
    }

    public func loadStructuredDocument(itemId: String) throws -> StructuredDocument? {
        let documents: [StructuredDocument] = try loadByItem(kind: Self.structuredDocumentKind, itemId: itemId)
        return documents.max { $0.extraction.version < $1.extraction.version }
    }

    /// The items that have a structured document, read without decoding the
    /// documents, so the Library can mark new-reader PDFs cheaply (#359).
    public func loadStructuredDocumentItemIds() throws -> Set<String> {
        let timer = StoreReadTimer(readMeter, method: #function)
        var itemIds: Set<String> = []
        defer { timer?.finish(rows: itemIds.count, bytes: itemIds.reduce(0) { $0 + $1.utf8.count }) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                connection,
                "SELECT DISTINCT item_id FROM records WHERE kind = ? AND item_id IS NOT NULL;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_structured_document_item_ids")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: Self.structuredDocumentKind)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                itemIds.insert(String(cString: raw))
            }
            return itemIds
        }
    }

    /// Margins other people shared, counted per item for the Library rows (#1792). One query in SQL:
    /// opening the Library must not decode every imported recording, transcript and anchor. Only a
    /// layer the listener hasn't deleted counts, as on the Margins screens (which ignore the on/off switch).
    ///
    /// Each Margin's payload is parsed once, and its layer is found by the primary key `(kind, id)`: the
    /// layer match must stay a plain equality on `layer.id`, or SQLite scans every layer for every Margin
    /// (layers x Margins JSON parses on each Library read). A broken payload gives NULL, which matches nothing.
    /// It joins on the layer's `item_id`, not the Margin's, which can still be NULL for a Margin imported
    /// before its layer found its item.
    static let sharedMarginTalliesSQL = """
        SELECT layer.item_id, COUNT(note.id),
               SUM(CASE WHEN json_extract(note.payload, '$.firstHeardAt') IS NULL THEN 1 ELSE 0 END)
        FROM records AS note
        JOIN records AS layer
          ON layer.kind = ?2
         AND layer.id = CASE WHEN json_valid(note.payload) THEN json_extract(note.payload, '$.layerId') END
        WHERE note.kind = ?1 AND layer.item_id IS NOT NULL
          AND CASE WHEN json_valid(layer.payload) THEN json_extract(layer.payload, '$.deletedAt') IS NULL ELSE 0 END
        GROUP BY layer.item_id;
        """

    public func loadSharedMarginTallies() throws -> [String: SharedMarginTally] {
        let timer = StoreReadTimer(readMeter, method: #function)
        var rowCount = 0
        defer { timer?.finish(rows: rowCount, bytes: 0) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, Self.sharedMarginTalliesSQL, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_shared_margin_tallies")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: "imported_commentary_interjection")
            bind(statement, index: 2, value: "imported_commentary_layer")
            var tallies: [String: SharedMarginTally] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                rowCount += 1
                tallies[String(cString: raw)] = SharedMarginTally(
                    total: Int(sqlite3_column_int64(statement, 1)),
                    new: Int(sqlite3_column_int64(statement, 2))
                )
            }
            return tallies
        }
    }

    /// SQLite's plan for `loadSharedMarginTallies`, one line per step, so a test can tell a primary-key
    /// lookup of each layer from a scan of every layer.
    func sharedMarginTalliesQueryPlan() throws -> [String] {
        try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "EXPLAIN QUERY PLAN " + Self.sharedMarginTalliesSQL, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_shared_margin_tallies_plan")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: "imported_commentary_interjection")
            bind(statement, index: 2, value: "imported_commentary_layer")
            var steps: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 3) { steps.append(String(cString: raw)) }
            }
            return steps
        }
    }

    public func applyStructuredDocumentUpgrade(_ upgrade: StructuredDocumentUpgrade) throws {
        let itemId = upgrade.item.id
        try withTransaction {
            try StructuredDocumentUpgrader.requireUnchangedSincePlanned(upgrade, repository: self)
            try saveItem(upgrade.item)
            try deleteRecords(kind: "listening_map", itemId: itemId)
            if let map = upgrade.listeningMap {
                try save(kind: "listening_map", id: map.id, sessionId: nil, itemId: itemId, value: map)
            }
            for interjection in upgrade.interjections { try saveInterjection(interjection) }
            for session in upgrade.sessions { try saveSession(session) }
            for manifest in try loadPreparedAudioManifests(itemId: itemId) { try deletePreparedAudioManifest(id: manifest.id) }
            for job in try loadAudioPreparationJobs(itemId: itemId) { try deleteAudioPreparationJob(id: job.id) }
            try saveStructuredDocument(upgrade.document, itemId: itemId)
        }
    }
}

/// Publisher audio (#545) lives in the records table as kind "publisher_audio", one row per
/// item, keyed and linked by the item id. No table or column changes, and schema_version stays
/// 5: Build 29 selects records by kind and never reads this one, and deleting the item removes it.
extension SQLiteSessionStore: PublisherAudioRepository {
    static let publisherAudioKind = "publisher_audio"

    public func savePublisherAudio(_ audio: PublisherAudio) throws {
        try save(kind: Self.publisherAudioKind, id: audio.itemId, sessionId: nil, itemId: audio.itemId, value: audio)
    }

    public func loadPublisherAudio(itemId: String) throws -> PublisherAudio? {
        try loadOptional(kind: Self.publisherAudioKind, id: itemId)
    }
}

/// Community map uploads (#552) live in the records table as kind "community_map_upload", one
/// row per episode key. The row is not linked to an item, so deleting one Library copy keeps the
/// episode's history and re-importing it doesn't send the transcript again. No table or column
/// changes, and schema_version stays the same: Build 29 selects records by kind and never reads
/// this one.
extension SQLiteSessionStore: CommunityMapUploadRepository {
    static let communityMapUploadKind = "community_map_upload"

    public func saveCommunityMapUpload(_ record: CommunityMapUploadRecord) throws {
        try save(kind: Self.communityMapUploadKind, id: record.id, sessionId: nil, itemId: nil, value: record)
    }

    public func loadCommunityMapUpload(episodeKey: String) throws -> CommunityMapUploadRecord? {
        try loadOptional(kind: Self.communityMapUploadKind, id: episodeKey)
    }

    public func loadCommunityMapUploads() throws -> [CommunityMapUploadRecord] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", [Self.communityMapUploadKind])
    }
}
