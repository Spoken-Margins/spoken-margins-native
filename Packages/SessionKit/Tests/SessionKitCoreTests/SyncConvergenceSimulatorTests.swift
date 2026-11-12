import Foundation
import XCTest
@testable import SessionKit

/// #4152: several devices edit at once over a network that drops, repeats and reorders messages, go offline, are
/// reinstalled or restored from an old backup, and one runs an older build. When the network is quiet again, every
/// device must hold the same records, and nothing the listener wrote may be gone.
///
/// "Nothing lost" is checked against a ledger the simulator keeps itself, not against the merge code: each time a device
/// writes a field, the ledger notes which versions it held (they are replaced) and which it made (it is live). At the
/// end, the versions a field holds must be exactly the live ones.
final class SyncConvergenceSimulatorTests: XCTestCase {
    func testManySeedsConverge() throws {
        for seed in UInt64(1)...40 {
            let simulation = SyncSimulation(seed: seed, deviceCount: 4, olderBuildIndex: 2)
            simulation.run(steps: 600)
            try simulation.settle()
            try simulation.assertConverged(context: "seed \(seed)")
        }
    }

    func testTwoDevicesConverge() throws {
        for seed in UInt64(100)...120 {
            let simulation = SyncSimulation(seed: seed, deviceCount: 2, olderBuildIndex: nil)
            simulation.run(steps: 400)
            try simulation.settle()
            try simulation.assertConverged(context: "two devices, seed \(seed)")
        }
    }

    func testADeviceBackAfterNinetyDaysKeepsItsLocalDataAndTheLibraryStillConverges() throws {
        for seed in UInt64(200)...215 {
            let simulation = SyncSimulation(seed: seed, deviceCount: 3, olderBuildIndex: nil)
            simulation.run(steps: 200)
            try simulation.settle()
            simulation.setOffline(2)
            simulation.advanceDays(10)
            simulation.run(steps: 150, onlyDevices: [0, 1])     // the others carry on, deleting and editing
            simulation.author(device: 2, steps: 20)             // the sleeper writes offline
            simulation.advanceDays(100)
            simulation.compactCloudAndDevices(except: [2])
            simulation.setOnline(2)
            try simulation.settle()
            try simulation.assertConverged(context: "ninety-day return, seed \(seed)", relaxedForPurgedDeletes: true)
        }
    }

    func testTheRandomRunsReallyMeetTheTroubleTheyAreMeantToMeet() throws {
        var totals: [String: Int] = [:]
        for seed in UInt64(1)...80 {
            let simulation = SyncSimulation(seed: seed, deviceCount: 4, olderBuildIndex: 2)
            simulation.run(steps: 600)
            try simulation.settle()
            try simulation.assertConverged(context: "coverage run, seed \(seed)")
            for (name, count) in simulation.stats { totals[name, default: 0] += count }
        }
        for name in ["dropped", "duplicated", "reordered", "offlineToggles", "reinstalls", "restores", "racesSeen", "othersPicked",
                     "parkedByOlderBuild", "unknownFieldKept", "deletes", "undeletes", "seeks", "staleResponsesAfterReinstall"] {
            XCTAssertGreaterThan(totals[name] ?? 0, 0, "the simulator never produced: \(name)")
        }
    }

    func testTheSimulatorCanFail() throws {
        // A guard on the guard: break convergence on purpose and the check must say so.
        let simulation = SyncSimulation(seed: 7, deviceCount: 3, olderBuildIndex: nil)
        simulation.run(steps: 300)
        try simulation.settle()
        try simulation.assertConverged(context: "before")
        simulation.corruptOneRecordOnDevice(1)
        XCTAssertThrowsError(try simulation.assertConverged(context: "corrupted"))
    }
}

// MARK: - The simulator

final class SyncSimulation {
    struct FieldKey: Hashable { var id: SyncRecordID; var field: String }

    struct Node {
        var replica: SyncReplica
        var online = true
        var snapshot: SyncReplica?
        var skewMillis: Int64
        var installs = 0
    }

    enum Message {
        case push(from: Int, records: [SyncRecord])
        case ack(to: Int, records: [SyncRecord])
        case pullRequest(from: Int, since: Int, lastSyncedMillis: Int64?)
        case pullResponse(to: Int, SyncTestCloud.Pull)
    }

    struct SimulationError: Error, CustomStringConvertible { var description: String }

    private(set) var nodes: [Node] = []
    private var cloud = SyncTestCloud()
    private var random: SeededRandom
    private var now: Int64 = 1_760_000_000_000
    private var network: [Message] = []
    private var dropRate = 0.10
    private var duplicateRate = 0.10

    // The ledger.
    private var live: [FieldKey: Set<SyncStamp>] = [:]
    private var authoredPlayStamps: [SyncRecordID: SyncStamp] = [:]
    private(set) var authoredMarginIDs: Set<String> = []
    private var authoredNoteIDs: Set<String> = []
    private var everDeleted: Set<SyncRecordID> = []
    /// The status each authored status version carries, so "deleted" is read from the live versions, not remembered.
    private var statusByStamp: [SyncStamp: String] = [:]
    private var counter = 0
    /// What the run met, so a test can show it was not vacuous.
    private(set) var stats: [String: Int] = [:]
    private func count(_ name: String) { stats[name, default: 0] += 1 }

    private let itemKeys = ["ep-1", "ep-2", "src-3", "txt-4", "spoken-note-n0"]
    private let skews: [Int64] = [0, -365 * 86_400_000, 2 * 86_400_000, -3_600_000, 5_000]

    init(seed: UInt64, deviceCount: Int, olderBuildIndex: Int?) {
        random = SeededRandom(seed: seed)
        for index in 0..<deviceCount {
            nodes.append(Node(
                replica: SyncReplica(device: "d\(index)", supportedSchemaVersion: index == olderBuildIndex ? 1 : 2),
                skewMillis: skews[index % skews.count]
            ))
        }
    }

    // MARK: Running

    func run(steps: Int, onlyDevices: [Int]? = nil) {
        for _ in 0..<steps {
            now += Int64.random(in: 500...30_000, using: &random)
            let device = onlyDevices?.randomElement(using: &random) ?? Int.random(in: 0..<nodes.count, using: &random)
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<30: authorStep(device)
            case 30..<48: sendPush(device)
            case 48..<60: sendPullRequest(device)
            case 60..<88: deliverOne()
            case 88..<91: nodes[device].online.toggle(); count("offlineToggles")
            case 91: reinstall(device)
            case 92: nodes[device].snapshot = nodes[device].replica
            case 93: restoreSnapshot(device)
            default: break
            }
        }
    }

    func author(device: Int, steps: Int) {
        for _ in 0..<steps {
            now += Int64.random(in: 500...30_000, using: &random)
            authorStep(device)
        }
    }

    func setOffline(_ device: Int) { nodes[device].online = false }
    func setOnline(_ device: Int) { nodes[device].online = true }
    func advanceDays(_ days: Int64) { now += days * 86_400_000 }

    func compactCloudAndDevices(except: Set<Int>) {
        cloud.compactTombstones(nowMillis: now)
        for index in nodes.indices where !except.contains(index) { nodes[index].replica.compactTombstones(nowMillis: now) }
    }

    /// Quiet network, everyone online: rounds of push, pull and delivery until nothing changes.
    func settle() throws {
        dropRate = 0
        duplicateRate = 0
        for index in nodes.indices { nodes[index].online = true }
        var previous: [[SyncRecordID: SyncRecord]] = []
        for _ in 0..<60 {
            for index in nodes.indices { sendPush(index); sendPullRequest(index) }
            while !network.isEmpty { deliverOne() }
            let state = nodes.map(\.replica.records)
            if state == previous, nodes.allSatisfy({ $0.replica.pending.isEmpty }) { return }
            previous = state
        }
        throw SimulationError(description: "did not settle in 60 rounds")
    }

    // MARK: Network

    private func sendPush(_ device: Int) {
        guard nodes[device].online else { return }
        let outbox = nodes[device].replica.outbox
        if !outbox.isEmpty { network.append(.push(from: device, records: outbox)) }
    }

    private func sendPullRequest(_ device: Int) {
        guard nodes[device].online else { return }
        let replica = nodes[device].replica
        network.append(.pullRequest(from: device, since: replica.pullToken, lastSyncedMillis: replica.lastSyncedMillis))
    }

    private func deliverOne() {
        guard !network.isEmpty else { return }
        let index = Int.random(in: 0..<network.count, using: &random)       // any order
        let message = network[index]
        if index != 0 { count("reordered") }
        if Double.random(in: 0..<1, using: &random) < duplicateRate { network.append(message); count("duplicated") }  // sent again
        network.remove(at: index)
        if Double.random(in: 0..<1, using: &random) < dropRate { count("dropped"); return }                          // lost
        switch message {
        case let .push(from, records):
            cloud.push(records, nowMillis: now)
            network.append(.ack(to: from, records: records))
        case let .ack(to, records):
            if nodes[to].online { nodes[to].replica.acknowledge(records) }
        case let .pullRequest(from, since, last):
            network.append(.pullResponse(to: from, cloud.pull(since: since, lastSyncedMillis: last)))
        case let .pullResponse(to, pull):
            guard nodes[to].online else { return }
            if pull.since > nodes[to].replica.pullToken, !pull.resync { count("staleResponsesAfterReinstall") }
            if pull.resync {
                count("resyncs")
                nodes[to].replica.resyncFromScratch(cloudRecords: pull.records, cloudToken: pull.token, nowMillis: now)
            } else {
                nodes[to].replica.receive(pull.records)
                if nodes[to].replica.records.values.contains(where: { $0.fields.values.contains { $0.heads.count > 1 } }) { count("racesSeen") }
                nodes[to].replica.pullCompleted(since: pull.since, upTo: pull.token, nowMillis: now)
            }
        }
    }

    // MARK: Device life

    /// A reinstall loses what only that device held, so it happens only once the cloud has confirmed everything it made.
    private func reinstall(_ device: Int) {
        guard nodes[device].replica.pending.isEmpty else { return }
        nodes[device].installs += 1
        count("reinstalls")
        let supported = nodes[device].replica.supportedSchemaVersion
        nodes[device].replica = SyncReplica(device: "d\(device)-install\(nodes[device].installs)", supportedSchemaVersion: supported)
        nodes[device].snapshot = nil
    }

    private func restoreSnapshot(_ device: Int) {
        guard nodes[device].replica.pending.isEmpty, let snapshot = nodes[device].snapshot else { return }
        nodes[device].replica = snapshot
        count("restores")
    }

    func corruptOneRecordOnDevice(_ device: Int) {
        guard let id = nodes[device].replica.records.keys.sorted().first else { return }
        var clock = SyncClock(device: "intruder")
        nodes[device].replica.receive([{
            var record = SyncRecord(id: id)
            record.set("extra", .string("only here"), clock: &clock, wallMillis: now)
            return record
        }()])
        // Forget that it is owed to the cloud, so the devices stay apart.
        nodes[device].replica.acknowledge([nodes[device].replica.records[id]!])
    }

    // MARK: Authoring (every write goes through `write`, which keeps the ledger)

    private func wall(_ device: Int) -> Int64 { now + nodes[device].skewMillis }

    private func write(_ device: Int, _ id: SyncRecordID, schemaVersion: Int? = nil, _ field: String, _ value: SyncValue) {
        let key = FieldKey(id: id, field: field)
        let before = Set(nodes[device].replica.record(id)?.register(field)?.heads.map(\.stamp) ?? [])
        let millis = wall(device)
        do {
            try nodes[device].replica.edit(id, schemaVersion: schemaVersion) { record, clock in
                record.set(field, value, clock: &clock, wallMillis: millis)
            }
        } catch { return }       // an older build refuses a record it cannot read
        let after = Set(nodes[device].replica.record(id)!.register(field)!.heads.map(\.stamp))
        guard after != before else { return }
        if field == "status", value == .string("deleted") { everDeleted.insert(id); count("deletes") }
        if field == "status", value == .string("active"), before.count > 0 { count("undeletes") }
        if field == "place", value.objectValue?["cause"]?.stringValue == "seek" { count("seeks") }
        live[key, default: []].subtract(before)
        live[key, default: []].formUnion(after.subtracting(before))
        if field == "status", let text = value.stringValue { for stamp in after.subtracting(before) { statusByStamp[stamp] = text } }
    }

    private func writeNamed(_ device: Int, _ id: SyncRecordID, _ field: String, _ text: String) {
        counter += 1
        write(device, id, field, .string("\(text) #\(counter) by d\(device)"))
    }

    private func recordIDs(_ device: Int, kind: String) -> [SyncRecordID] {
        nodes[device].replica.readableRecords.map(\.id).filter { $0.kind == kind }
    }

    private func authorStep(_ device: Int) {
        let pick = Int.random(in: 0..<100, using: &random)
        switch pick {
        case 0..<14: createMargin(device)
        case 14..<34:
            if let id = recordIDs(device, kind: "margin").randomElement(using: &random) {
                writeNamed(device, id, MarginSync.textFields.randomElement(using: &random)!, "words")
            }
        case 34..<42:
            if let id = recordIDs(device, kind: "margin").randomElement(using: &random) {
                let deleted = nodes[device].replica.record(id)?.isDeleted ?? false
                write(device, id, "status", .string(deleted ? "active" : "deleted"))
            }
        case 42..<46:
            if let id = recordIDs(device, kind: "margin").randomElement(using: &random) { write(device, id, "isStarredForSharing", .bool(Bool.random(using: &random))) }
        case 46..<50:
            if let id = recordIDs(device, kind: "margin").randomElement(using: &random), nodes[device].replica.supportedSchemaVersion >= 2 {
                writeNamed(device, id, "reaction", "heart")       // a field the older build does not know
            }
        case 50..<56: createNote(device)
        case 56..<64:
            if let id = recordIDs(device, kind: "item").filter({ $0.key.hasPrefix("spoken-note-") }).randomElement(using: &random) {
                if Int.random(in: 0..<6, using: &random) == 0 {
                    let deleted = nodes[device].replica.record(id)?.isDeleted ?? false
                    write(device, id, "status", .string(deleted ? "active" : "deleted"))
                } else {
                    writeNamed(device, id, ["text", "title"].randomElement(using: &random)!, "note")
                }
            }
        case 64..<74: collectionStep(device)
        case 74..<88: placeStep(device)
        case 88..<93: pickOtherVersion(device)
        default:
            if nodes[device].replica.supportedSchemaVersion >= 2 {      // a record only a newer build can read
                counter += 1
                write(device, .item("clip-\(counter)"), schemaVersion: 2, "body", .string("clip \(counter)"))
            }
        }
    }

    private func createMargin(_ device: Int) {
        counter += 1
        let id = SyncRecordID.margin("m\(counter)")
        authoredMarginIDs.insert(id.key)
        write(device, id, "itemKey", .string(itemKeys.randomElement(using: &random)!))
        write(device, id, "createdAt", .number(Double(wall(device))))
        write(device, id, "anchor", .object(["startChar": .number(Double(counter)), "endChar": .number(Double(counter + 5))]))
        write(device, id, "captureKind", .string("written"))
        write(device, id, "status", .string("active"))
        writeNamed(device, id, "transcript", "first words")
        writeNamed(device, id, "displayText", "first words")
    }

    private func createNote(_ device: Int) {
        counter += 1
        let id = SyncRecordID.item("spoken-note-n\(counter)")
        authoredNoteIDs.insert(id.key)
        write(device, id, "status", .string("active"))
        writeNamed(device, id, "title", "title")
        writeNamed(device, id, "text", "note")
    }

    private func collectionStep(_ device: Int) {
        let known = recordIDs(device, kind: "collection")
        guard let id = known.randomElement(using: &random), Int.random(in: 0..<4, using: &random) > 0 else {
            counter += 1
            write(device, .collection("c\(Int.random(in: 0..<3, using: &random))"), "name", .string("Course \(counter)"))
            return
        }
        let key = itemKeys.randomElement(using: &random)!
        switch Int.random(in: 0..<3, using: &random) {
        case 0:
            write(device, id, CollectionSync.memberField(key), .bool(true))
            appendToOrder(device, id, key)
        case 1:
            write(device, id, CollectionSync.memberField(key), .bool(false))
        default:
            let order = itemKeys.shuffled(using: &random)
            write(device, id, "order", .array(order.map(SyncValue.string)))
        }
    }

    private func appendToOrder(_ device: Int, _ id: SyncRecordID, _ key: String) {
        var order = (nodes[device].replica.record(id)?["order"]?.arrayValue ?? [])
        if !order.contains(.string(key)) { order.append(.string(key)) }
        write(device, id, "order", .array(order))
    }

    private func placeStep(_ device: Int) {
        let item = itemKeys.randomElement(using: &random)!
        let id = SyncRecordID.place(item)
        let revision = Int.random(in: 0..<5, using: &random) == 0 ? "rev-2" : "rev-1"
        let key = FieldKey(id: id, field: "place")
        switch Int.random(in: 0..<5, using: &random) {
        case 0:
            write(device, id, "completion", .object(["revision": .string(revision)]))
        default:
            let value = SyncValue.object([
                "position": .number(Double(Int.random(in: 0..<3_600_000, using: &random))),
                "revision": .string(revision),
                "cause": .string(Bool.random(using: &random) ? "play" : "seek")
            ])
            write(device, id, "place", value)
            if let stamp = nodes[device].replica.record(id)?.register("place")?.current.stamp, live[key]?.contains(stamp) == true {
                authoredPlayStamps[id] = max(authoredPlayStamps[id] ?? stamp, stamp)
            }
        }
    }

    private func pickOtherVersion(_ device: Int) {
        for id in recordIDs(device, kind: "margin") + recordIDs(device, kind: "item") {
            guard let record = nodes[device].replica.record(id) else { continue }
            for field in MarginSync.textFields + SpokenNoteSync.textFields {
                if let other = record.otherVersions(of: field).first {
                    count("othersPicked")
                    write(device, id, field, other)
                    return
                }
            }
        }
    }

    // MARK: Checks

    func assertConverged(context: String, relaxedForPurgedDeletes: Bool = false) throws {
        func fail(_ message: String) -> SimulationError { SimulationError(description: "\(context): \(message)") }
        let reference = nodes[0].replica.records
        for (index, node) in nodes.enumerated() where node.replica.records != reference {
            let ids = Set(reference.keys).union(node.replica.records.keys).filter { reference[$0] != node.replica.records[$0] }
            throw fail("device \(index) differs from device 0 on \(ids.sorted().prefix(3).map { "\($0.kind)/\($0.key)" })")
        }
        guard cloud.records == reference else { throw fail("the cloud differs from the devices") }

        // Nothing the listener made is gone.
        // After a 90-day gap a delete's marker is forgotten on purpose, so only a Margin or note whose live status is
        // "deleted" may be gone. One that was deleted and then undeleted must still be here.
        func mayBeGone(_ id: SyncRecordID) -> Bool {
            guard relaxedForPurgedDeletes, let stamps = live[FieldKey(id: id, field: "status")], !stamps.isEmpty else { return false }
            return stamps.allSatisfy { statusByStamp[$0] == "deleted" }
        }
        for id in authoredMarginIDs where reference[.margin(id)] == nil && !mayBeGone(.margin(id)) { throw fail("Margin \(id) is missing") }
        for id in authoredNoteIDs where reference[.item(id)] == nil && !mayBeGone(.item(id)) { throw fail("Spoken Note \(id) is missing") }

        // The versions a field holds are exactly the live ones: none dropped, none brought back. After a 90-day gap a
        // record that was ever deleted may come back from the sleeper's old copy with its older versions, so those are skipped.
        for (id, record) in reference where !(relaxedForPurgedDeletes && everDeleted.contains(id)) {
            for (field, register) in record.fields {
                let held = Set(register.heads.map(\.stamp))
                let expected = live[FieldKey(id: id, field: field)] ?? []
                guard held == expected else { throw fail("\(id.kind)/\(id.key).\(field) holds \(held.count) versions, the ledger says \(expected.count) are live") }
            }
        }
        for (id, stamp) in authoredPlayStamps {
            guard let place = reference[id].flatMap(ListeningPlaceSync.place(of:)), place.stamp == stamp else {
                throw fail("place \(id.key) is not the most recent play")
            }
        }
        for (id, record) in reference where id.kind == "collection" {
            let ordered = CollectionSync.orderedItemKeys(of: record)
            guard Set(ordered).count == ordered.count else { throw fail("collection \(id.key) lists an item twice") }
            let members = Set(record.fields.compactMap { name, register -> String? in
                name.hasPrefix("member/") && register.current.value == .bool(true) ? String(name.dropFirst(7)) : nil
            })
            guard Set(ordered) == members else { throw fail("collection \(id.key) order and members differ") }
        }
        // The older build holds a newer build's records untouched and counts them.
        for node in nodes where node.replica.supportedSchemaVersion == 1 {
            let newer = reference.values.filter { $0.schemaVersion > 1 }.count
            if newer > 0 { count("parkedByOlderBuild") }
            if reference.values.contains(where: { $0.schemaVersion <= 1 && $0["reaction"] != nil }) { count("unknownFieldKept") }
            guard node.replica.parkedRecordCount == newer else { throw fail("older build parked \(node.replica.parkedRecordCount), expected \(newer)") }
        }
    }
}
