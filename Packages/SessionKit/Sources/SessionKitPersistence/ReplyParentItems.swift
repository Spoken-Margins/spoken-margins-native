import Foundation
import SessionKit
import SQLite3

extension SQLiteSessionStore {
    /// The items holding the listener's own active Margins that went out under any of these packet identities
    /// (`sharedAs`), so a friend's replies can land on the row that holds the Margins they answer, whatever edition of
    /// the episode the friend's copy is (#5286). Only Margins that were shared at all are parsed (a string search skips
    /// the rest first), as in `notAnEchoOfOwnMarginSQL`; a broken payload or a list element that is not an object
    /// matches nothing. One query per identity: a replies packet names a handful.
    public func itemIdsHoldingOwnMargins(sharedAs identities: [MarginPacketIdentity]) throws -> Set<String> {
        guard !identities.isEmpty else { return [] }
        let timer = StoreReadTimer(readMeter, method: #function)
        var itemIds: Set<String> = []
        defer { timer?.finish(rows: itemIds.count, bytes: itemIds.reduce(0) { $0 + $1.utf8.count }) }
        return try withReadConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, Self.itemsHoldingOwnMarginSQL, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_items_holding_own_margins")
            }
            defer { sqlite3_finalize(statement) }
            for identity in Set(identities) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, value: identity.packageDigest)
                bind(statement, index: 2, value: identity.packageScopedId)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let raw = sqlite3_column_text(statement, 0) else { continue }
                    itemIds.insert(String(cString: raw))
                }
            }
            return itemIds
        }
    }

    static let itemsHoldingOwnMarginSQL = """
        SELECT DISTINCT own.item_id FROM records AS own
        JOIN json_each(CASE WHEN json_valid(own.payload) THEN own.payload ELSE '{}' END, '$.sharedAs') AS identity
        WHERE own.kind = 'interjection' AND own.item_id IS NOT NULL
          AND instr(own.payload, '"sharedAs"') > 0
          AND CASE WHEN json_valid(own.payload) THEN json_extract(own.payload, '$.status') = 'active' ELSE 0 END
          AND identity.type = 'object'
          AND json_extract(identity.value, '$.packageDigest') = ?1
          AND json_extract(identity.value, '$.packageScopedId') = ?2;
        """
}
