import Foundation

/// How long a deleted record's marker is kept, from the delete (owner's call, 2026-11-12: "agree", 90 days).
public enum SyncTombstonePolicy {
    public static let keepMillis: Int64 = 90 * 24 * 60 * 60 * 1000

    /// Kept for 90 days from the later of the delete and the moment the cloud received it (`receivedAtMillis`). A delete
    /// made on a phone that was offline for weeks has not been seen by the other devices yet, so its 90 days start when
    /// it reaches the cloud, not when it was made.
    public static func isExpired(_ record: SyncRecord, nowMillis: Int64, receivedAtMillis: Int64? = nil) -> Bool {
        guard let deletedAt = record.deletedAtMillis else { return false }
        return nowMillis - max(deletedAt, receivedAtMillis ?? deletedAt) > keepMillis
    }
}

/// One device's side of sync: its copy of every sync record, its clock, what it has not yet pushed, and how far it has
/// pulled. It holds no transport. A CloudKit adapter (slice 2) and the test cloud both drive it through the same calls.
///
/// Local first: `edit` only changes this copy and marks the record to push, so a refused or slow sync never blocks a save.
public struct SyncReplica: Sendable {
    public enum EditError: Error, Equatable, Sendable {
        /// The record is from a newer reading than this build supports. It is kept untouched and not editable here.
        case unreadable(SyncRecordID)
    }

    public let device: String
    /// The newest record reading this build understands.
    public let supportedSchemaVersion: Int
    public private(set) var clock: SyncClock
    public private(set) var records: [SyncRecordID: SyncRecord] = [:]
    /// Records changed here that the cloud has not confirmed.
    public private(set) var pending: Set<SyncRecordID> = []
    /// How far this device has pulled, in the cloud's own counting.
    public private(set) var pullToken: Int = 0
    /// The wall time of the last pull that completed, for the 90-day rule. Nil before the first.
    public private(set) var lastSyncedMillis: Int64?

    public init(device: String, supportedSchemaVersion: Int = 1) {
        self.device = device
        self.supportedSchemaVersion = supportedSchemaVersion
        clock = SyncClock(device: device)
    }

    /// Records this build can read. The rest are parked: kept, counted, never edited.
    public var readableRecords: [SyncRecord] {
        records.values.filter { $0.schemaVersion <= supportedSchemaVersion }.sorted { $0.id < $1.id }
    }

    public var parkedRecordCount: Int { records.values.filter { $0.schemaVersion > supportedSchemaVersion }.count }

    public func record(_ id: SyncRecordID) -> SyncRecord? { records[id] }

    /// Makes or changes a record locally. A new record is born at reading 1 unless the kind passes its own `schemaVersion`
    /// (`MarginSync.schemaVersion`), so a newer build's Margin is not hidden from an older one that could read it. `change` gets the record and this device's clock; every field it sets is stamped
    /// by that clock. A record the device cannot read is refused, never rewritten.
    @discardableResult
    public mutating func edit(
        _ id: SyncRecordID, schemaVersion: Int? = nil, _ change: (inout SyncRecord, inout SyncClock) -> Void
    ) throws -> SyncRecord {
        var record = records[id] ?? SyncRecord(id: id, schemaVersion: schemaVersion ?? 1)
        guard record.schemaVersion <= supportedSchemaVersion else { throw EditError.unreadable(id) }
        change(&record, &clock)
        records[id] = record
        pending.insert(id)
        return record
    }

    /// Records the cloud (or a test) should be sent, whole, oldest id first.
    public var outbox: [SyncRecord] { pending.sorted().compactMap { records[$0] } }

    /// The cloud confirmed it holds `confirmed` as pushed. A record edited since stays pending, so an old confirmation never
    /// drops a newer edit.
    public mutating func acknowledge(_ confirmed: [SyncRecord]) {
        for record in confirmed where records[record.id] == record { pending.remove(record.id) }
    }

    /// Takes in records from the cloud or another device, in any order, any number of times. Everything is merged field
    /// by field; nothing local is replaced. The clock observes every stamp so that later edits here are above them.
    public mutating func receive(_ incoming: [SyncRecord]) {
        for record in incoming {
            if let stamp = record.highestStamp { clock.observe(stamp) }
            let merged = records[record.id].map { $0.merged(with: record) } ?? record
            // If merging taught this device something the sender lacks, it owes the cloud the merged record.
            if merged != record { pending.insert(record.id) }
            records[record.id] = merged
        }
    }

    /// A pull finished. The response covered the cloud's changes after `since` up to `token`. If this device has not
    /// itself pulled up to `since` (a response that outlived a reinstall or a restore from backup), the records were still
    /// merged in, but the device has not caught up, so its position and its last-synced time do not move.
    public mutating func pullCompleted(since: Int, upTo token: Int, nowMillis: Int64) {
        guard since <= pullToken else { return }
        pullToken = max(pullToken, token)
        lastSyncedMillis = max(lastSyncedMillis ?? nowMillis, nowMillis)
    }

    /// Drops deleted-record markers older than 90 days, except one not yet confirmed by the cloud: forgetting a delete
    /// that was never pushed would let the Margin come back from the cloud.
    public mutating func compactTombstones(nowMillis: Int64) {
        for (id, record) in records where !pending.contains(id) && SyncTombstonePolicy.isExpired(record, nowMillis: nowMillis) {
            records[id] = nil
        }
    }

    /// A device back after more than 90 days may have missed a delete whose marker is gone. It is told to sync from
    /// scratch.
    public func needsFullResync(cloudPurgeFloorMillis: Int64) -> Bool {
        guard let last = lastSyncedMillis else { return false }
        return last < cloudPurgeFloorMillis
    }

    /// Sync from scratch, keeping local data: every local record is merged with the cloud's and pushed again. Nothing is
    /// deleted. A Margin deleted elsewhere whose marker has expired comes back, which is the safe failure.
    public mutating func resyncFromScratch(cloudRecords: [SyncRecord], cloudToken: Int, nowMillis: Int64) {
        pullToken = 0
        receive(cloudRecords)
        pending.formUnion(records.keys)
        pullCompleted(since: 0, upTo: cloudToken, nowMillis: nowMillis)
    }
}
