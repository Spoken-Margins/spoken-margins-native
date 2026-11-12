import Foundation

/// Which record a sync change is about: its kind and its key. The key is the CloudKit record name later, so two phones
/// that made the same thing make the same record.
public struct SyncRecordID: Codable, Hashable, Comparable, Sendable {
    public var kind: String
    public var key: String

    public init(kind: String, key: String) {
        self.kind = kind
        self.key = key
    }

    public static func < (lhs: SyncRecordID, rhs: SyncRecordID) -> Bool {
        (lhs.kind, lhs.key) < (rhs.kind, rhs.key)
    }

    public static func margin(_ id: String) -> SyncRecordID { SyncRecordID(kind: "margin", key: id) }
    public static func item(_ itemKey: String) -> SyncRecordID { SyncRecordID(kind: "item", key: itemKey) }
    public static func place(_ itemKey: String) -> SyncRecordID { SyncRecordID(kind: "place", key: itemKey) }
    public static func collection(_ id: String) -> SyncRecordID { SyncRecordID(kind: "collection", key: id) }
}

/// The sync layer's copy of one Margin, Spoken Note, listening place or collection: named fields, each a
/// `SyncRegister`. It lives beside the database, never in it (#4152), so no stored row and no packet changes.
///
/// A record holds only the fields somebody has written, so a change can be a record with one field (a delete that
/// reaches a device before the add does) and merging it in gives the same result in either order.
public struct SyncRecord: Codable, Equatable, Sendable {
    public static let statusField = "status"
    public static let deletedStatus = "deleted"
    public static let activeStatus = "active"

    public var id: SyncRecordID
    /// The newest reading of the record this device knows of. A device that reads less parks the record (`SyncReplica`)
    /// instead of editing what it cannot read. Fields it does not know, in a record it can read, are carried untouched.
    public var schemaVersion: Int
    public private(set) var fields: [String: SyncRegister]

    public init(id: SyncRecordID, schemaVersion: Int = 1, fields: [String: SyncRegister] = [:]) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.fields = fields
    }

    public subscript(field: String) -> SyncValue? { fields[field]?.current.value }

    public func otherVersions(of field: String) -> [SyncValue] { fields[field]?.otherValues ?? [] }

    public func register(_ field: String) -> SyncRegister? { fields[field] }

    /// The edits of a record never change another record's, so a merge of different ids is a caller's mistake; the
    /// result keeps `self`'s id and the fields of both.
    public func merged(with other: SyncRecord) -> SyncRecord {
        var result = self
        result.schemaVersion = max(schemaVersion, other.schemaVersion)
        for (name, register) in other.fields {
            result.fields[name] = fields[name].map { $0.merged(with: register) } ?? register
        }
        return result
    }

    /// A first edit of a field. Writing the value a field already has changes nothing.
    public mutating func set(_ field: String, _ value: SyncValue, clock: inout SyncClock, wallMillis: Int64) {
        if var register = fields[field] {
            register.write(value, clock: &clock, wallMillis: wallMillis)
            fields[field] = register
        } else {
            let stamp = clock.tick(wallMillis: wallMillis)
            fields[field] = SyncRegister(first: SyncVersion(value: value, stamp: stamp))
        }
    }

    /// The listener picked one of a field's versions. Every other version goes.
    public mutating func resolve(_ field: String, to value: SyncValue, clock: inout SyncClock, wallMillis: Int64) {
        guard var register = fields[field] else { return }
        register.resolve(to: value, clock: &clock, wallMillis: wallMillis)
        fields[field] = register
    }

    public var highestStamp: SyncStamp? { fields.values.map(\.highestStamp).max() }

    /// Delete is `status = "deleted"`, the Margin's own delete (`SessionEngine.deleteInterjection`), synced like any
    /// edit. A later `active` is an undelete and wins over the delete it follows.
    public var isDeleted: Bool { self[Self.statusField]?.stringValue == Self.deletedStatus }

    /// When the delete that now stands was made, for the 90-day rule. Nil unless the record is deleted.
    public var deletedAtMillis: Int64? {
        guard isDeleted else { return nil }
        return fields[Self.statusField]?.current.stamp.wallMillis
    }

    public mutating func markDeleted(clock: inout SyncClock, wallMillis: Int64) {
        set(Self.statusField, .string(Self.deletedStatus), clock: &clock, wallMillis: wallMillis)
    }

    public mutating func markActive(clock: inout SyncClock, wallMillis: Int64) {
        set(Self.statusField, .string(Self.activeStatus), clock: &clock, wallMillis: wallMillis)
    }
}
