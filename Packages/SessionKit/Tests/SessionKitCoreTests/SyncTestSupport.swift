import Foundation
@testable import SessionKit

/// A small deterministic random source, so a simulator failure names a seed that replays it.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the cloud does, kept to what sync relies on (and what CloudKit gives): it merges what it is pushed, counts its
/// changes so a device can ask for those after a point, and forgets expired delete markers.
struct SyncTestCloud {
    private(set) var records: [SyncRecordID: SyncRecord] = [:]
    private var changedAt: [SyncRecordID: Int] = [:]
    /// When the cloud last changed each record, by the cloud's own clock. A delete marker is kept 90 days from here.
    private var receivedAtMillis: [SyncRecordID: Int64] = [:]
    private(set) var token = 0
    /// A device last synced before this may have missed a delete whose marker has been forgotten.
    private(set) var purgeFloorMillis: Int64 = 0

    mutating func push(_ pushed: [SyncRecord], nowMillis: Int64) {
        for record in pushed {
            let merged = records[record.id].map { $0.merged(with: record) } ?? record
            if merged != records[record.id] {
                records[record.id] = merged
                token += 1
                changedAt[record.id] = token
                receivedAtMillis[record.id] = nowMillis
            }
        }
    }

    struct Pull {
        /// The change count the request asked from, which the replica checks against its own.
        var since: Int
        var records: [SyncRecord]
        var token: Int
        /// The device must sync from scratch: `records` is everything.
        var resync: Bool
    }

    func pull(since: Int, lastSyncedMillis: Int64?) -> Pull {
        if let last = lastSyncedMillis, last < purgeFloorMillis {
            return Pull(since: since, records: records.values.sorted { $0.id < $1.id }, token: token, resync: true)
        }
        let changed = records.values.filter { (changedAt[$0.id] ?? 0) > since }.sorted { $0.id < $1.id }
        return Pull(since: since, records: changed, token: token, resync: false)
    }

    mutating func compactTombstones(nowMillis: Int64) {
        for (id, record) in records where SyncTombstonePolicy.isExpired(record, nowMillis: nowMillis, receivedAtMillis: receivedAtMillis[id]) {
            // A device that last synced before the cloud received this marker has not seen the delete.
            purgeFloorMillis = max(purgeFloorMillis, receivedAtMillis[id] ?? nowMillis)
            records[id] = nil
            changedAt[id] = nil
            receivedAtMillis[id] = nil
        }
    }
}

extension SyncReplica {
    /// One reliable round with `cloud`: push everything pending, then pull. For tests that are not about the network.
    mutating func syncNow(with cloud: inout SyncTestCloud, nowMillis: Int64) {
        let outbox = outbox
        cloud.push(outbox, nowMillis: nowMillis)
        acknowledge(outbox)
        let pull = cloud.pull(since: pullToken, lastSyncedMillis: lastSyncedMillis)
        if pull.resync {
            resyncFromScratch(cloudRecords: pull.records, cloudToken: pull.token, nowMillis: nowMillis)
            let again = self.outbox
            cloud.push(again, nowMillis: nowMillis)
            acknowledge(again)
        } else {
            receive(pull.records)
            pullCompleted(since: pull.since, upTo: pull.token, nowMillis: nowMillis)
        }
    }
}

enum SyncFixtures {
    static func margin(id: String, text: String = "A thought.", status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: "local-item", sessionId: "local-session", targetType: .item, targetId: "local-item",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 4, endChar: 9, anchorBefore: "before", anchorAfter: "after"),
            audioPath: "recordings/\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: text,
            cleanedTranscript: nil, displayText: text, status: status
        )
    }
}
