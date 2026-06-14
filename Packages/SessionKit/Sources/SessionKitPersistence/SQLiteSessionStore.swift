import Foundation
import SessionKit
import SQLite3

public final class SQLiteSessionStore: SessionRepository {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("sqlite_open")
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func migrate() throws {
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
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
        try execute("CREATE INDEX IF NOT EXISTS records_session_idx ON records(kind, session_id);")
        try execute("CREATE INDEX IF NOT EXISTS records_item_idx ON records(kind, item_id);")
        try execute("INSERT OR REPLACE INTO metadata(key, value) VALUES('schema_version', '1');")
    }

    public func reset() throws {
        try execute("DELETE FROM records;")
    }

    public func loadItem(id: String) throws -> Item {
        try load(kind: "item", id: id)
    }

    public func saveItem(_ item: Item) throws {
        try save(kind: "item", id: item.id, sessionId: nil, itemId: item.id, value: item)
    }

    public func loadListeningMap(itemId: String) throws -> ListeningMap? {
        let maps: [ListeningMap] = try loadByItem(kind: "listening_map", itemId: itemId)
        return maps.first
    }

    public func saveListeningMap(_ map: ListeningMap) throws {
        try save(kind: "listening_map", id: map.id, sessionId: nil, itemId: map.itemId, value: map)
    }

    public func saveSession(_ session: Session) throws {
        try save(kind: "session", id: session.id, sessionId: session.id, itemId: session.itemId, value: session)
    }

    public func loadSession(id: String) throws -> Session? {
        try loadOptional(kind: "session", id: id)
    }

    public func loadSessions(itemId: String) throws -> [Session] {
        try loadByItem(kind: "session", itemId: itemId)
    }

    public func saveInterjection(_ interjection: Interjection) throws {
        try save(kind: "interjection", id: interjection.id, sessionId: interjection.sessionId, itemId: interjection.itemId, value: interjection)
    }

    public func loadInterjections(sessionId: String) throws -> [Interjection] {
        try loadBySession(kind: "interjection", sessionId: sessionId)
    }

    public func saveTurn(_ turn: ConversationTurn) throws {
        try save(kind: "turn", id: turn.id, sessionId: turn.sessionId, itemId: nil, value: turn)
    }

    public func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        try loadBySession(kind: "turn", sessionId: sessionId)
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

    public func listItems() throws -> [Item] {
        try query("SELECT payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["item"])
    }

    public func deleteItem(id: String) throws {
        var statement: OpaquePointer?
        let sql = "DELETE FROM records WHERE item_id = ? OR (kind = 'item' AND id = ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_delete_item")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: id)
        bind(statement, index: 2, value: id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_delete_item")
        }
    }

    private func save<T: Encodable>(kind: String, id: String, sessionId: String?, itemId: String?, value: T) throws {
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
        bind(statement, index: 2, value: id)
        bind(statement, index: 3, value: sessionId)
        bind(statement, index: 4, value: itemId)
        bind(statement, index: 5, value: payload)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_save")
        }
    }

    private func load<T: Decodable>(kind: String, id: String) throws -> T {
        guard let value: T = try loadOptional(kind: kind, id: id) else {
            throw SessionKitError.missingFixture("\(kind):\(id)")
        }
        return value
    }

    private func loadOptional<T: Decodable>(kind: String, id: String) throws -> T? {
        let values: [T] = try query("SELECT payload FROM records WHERE kind = ? AND id = ?;", [kind, id])
        return values.first
    }

    private func loadBySession<T: Decodable>(kind: String, sessionId: String) throws -> [T] {
        try query("SELECT payload FROM records WHERE kind = ? AND session_id = ? ORDER BY updated_at, id;", [kind, sessionId])
    }

    private func loadByItem<T: Decodable>(kind: String, itemId: String) throws -> [T] {
        try query("SELECT payload FROM records WHERE kind = ? AND item_id = ? ORDER BY updated_at, id;", [kind, itemId])
    }

    private func query<T: Decodable>(_ sql: String, _ values: [String]) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_query")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            bind(statement, index: Int32(index + 1), value: value)
        }
        var decoded: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let payload = String(cString: raw)
            guard let data = payload.data(using: .utf8) else { continue }
            decoded.append(try decoder.decode(T.self, from: data))
        }
        return decoded
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SessionKitError.persistenceFailed(message)
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
