import Foundation

/// A collection as a sync record (`collection/<id>`): its name, a membership flag per item key, and the order as a list
/// of item keys. Everything is a register, so a collection merges like any other record; `orderedItemKeys` reads it.
///
/// - Items present on either side stay: a key is in the collection when its membership register says so. Adding an
///   item on one phone and reordering on another keeps the item.
/// - The order is the one written last (highest stamp). An item that order does not list, because it was added on the
///   side with the older order, goes at the end, earliest added first, ties by key.
public enum CollectionSync {
    public static let schemaVersion = 1
    static let memberPrefix = "member/"

    /// The name of the register that says whether `itemKey` is in the collection.
    public static func memberField(_ itemKey: String) -> String { memberPrefix + itemKey }

    public static func create(id: String, name: String, itemKeys: [String], clock: inout SyncClock, wallMillis: Int64) -> SyncRecord {
        var record = SyncRecord(id: .collection(id), schemaVersion: schemaVersion)
        record.set("name", .string(name), clock: &clock, wallMillis: wallMillis)
        for key in itemKeys { record.set(memberPrefix + key, .bool(true), clock: &clock, wallMillis: wallMillis) }
        record.set("order", .array(itemKeys.map(SyncValue.string)), clock: &clock, wallMillis: wallMillis)
        return record
    }

    public static func add(_ itemKey: String, to record: inout SyncRecord, clock: inout SyncClock, wallMillis: Int64) {
        record.set(memberPrefix + itemKey, .bool(true), clock: &clock, wallMillis: wallMillis)
        var order = orderList(of: record)
        if !order.contains(itemKey) { order.append(itemKey) }
        record.set("order", .array(order.map(SyncValue.string)), clock: &clock, wallMillis: wallMillis)
    }

    public static func remove(_ itemKey: String, from record: inout SyncRecord, clock: inout SyncClock, wallMillis: Int64) {
        record.set(memberPrefix + itemKey, .bool(false), clock: &clock, wallMillis: wallMillis)
    }

    /// The listener's new order of the items now in the collection.
    public static func reorder(_ itemKeys: [String], in record: inout SyncRecord, clock: inout SyncClock, wallMillis: Int64) {
        record.set("order", .array(itemKeys.map(SyncValue.string)), clock: &clock, wallMillis: wallMillis)
    }

    public static func name(of record: SyncRecord) -> String? { record["name"]?.stringValue }

    public static func orderedItemKeys(of record: SyncRecord) -> [String] {
        var members: [String: SyncStamp] = [:]
        for (field, register) in record.fields where field.hasPrefix(memberPrefix) && register.current.value == .bool(true) {
            members[String(field.dropFirst(memberPrefix.count))] = register.current.stamp
        }
        var seen = Set<String>()
        var result = orderList(of: record).filter { members[$0] != nil && seen.insert($0).inserted }
        let unlisted = members.filter { !seen.contains($0.key) }
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        result.append(contentsOf: unlisted.map(\.key))
        return result
    }

    private static func orderList(of record: SyncRecord) -> [String] {
        (record["order"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
