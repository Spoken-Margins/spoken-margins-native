import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader

/// Checks packets the way a group of listeners would meet them.
///
/// 1. Each packet reads in the current reader, and imports into Build 29 with the same Margins.
/// 2. Packets on the same item import into a fresh SQLite Library in every order (all orders up
///    to five packets, then 120 shuffles). Every order must give the same packets, Margins and
///    threads, and opening every packet again must add nothing.
/// 3. A sender who shared again (#858) must not leave the listener a second copy of any Margin.
enum CoopCheck {
    struct Report {
        var lines: [String] = []
        var failures = 0
        var passed: Bool { failures == 0 }
        var text: String {
            let verdict = failures == 0 ? "PASS" : "FAIL: \(failures) problem(s)"
            return (lines + [warnings == 0 ? verdict : "\(verdict), \(warnings) warning(s)"]).joined(separator: "\n")
        }

        mutating func pass(_ line: String) { lines.append("  ok    \(line)") }
        mutating func note(_ line: String) { lines.append("  note  \(line)") }
        mutating func warn(_ line: String) { lines.append("  WARN  \(line)"); warnings += 1 }
        var warnings = 0
        mutating func fail(_ line: String) { lines.append("  FAIL  \(line)"); failures += 1 }
    }

    static func run(_ urls: [URL]) throws -> Report {
        var report = Report()
        var packets: [OpenedPacket] = []
        defer { packets.forEach { try? FileManager.default.removeItem(at: $0.assetFolder) } }

        report.lines.append("Readers")
        for url in urls {
            let name = url.lastPathComponent
            let packet: OpenedPacket
            do {
                packet = try OpenedPacket.open(url)
            } catch {
                report.fail("\(name): current reader rejected it: \(error)")
                do {
                    let shipped = try ShippedPacketReader.importedMargins(at: url)
                    report.note("\(name): Build 29 still imports it (\(shipped.count) Margin(s))")
                } catch {
                    report.note("\(name): Build 29 rejects it too: \(error)")
                }
                continue
            }
            if ListeningMapPacket.isMapPacket(packet.contents.manifest) {
                // A map-only packet has no Margins to merge. It must read here and be refused, in the usual
                // words, by every earlier build (#1471).
                checkMapPacket(packet, url: url, report: &report)
                try? FileManager.default.removeItem(at: packet.assetFolder)
                continue
            }
            packets.append(packet)
            let expected = packet.margins.map { ($0.packageScopedId, $0.defaultRepresentation?.approvedTranscript ?? "") }
            do {
                let shipped = try ShippedPacketReader.importedMargins(at: url)
                let got = shipped.map { ($0.packageScopedId, $0.approvedTranscript) }
                if got.map(\.0).sorted() == expected.map(\.0).sorted(),
                   Dictionary(uniqueKeysWithValues: got) == Dictionary(uniqueKeysWithValues: expected) {
                    report.pass("\(name): both readers import \(expected.count) Margin(s) from \(packet.contents.manifest.senderDisplayLabel ?? "no sender")")
                } else {
                    report.fail("\(name): Build 29 imported \(got.map(\.0)) but the packet has \(expected.map(\.0))")
                }
            } catch {
                report.fail("\(name): \(error)")
            }
        }

        // Packets about the same work land on one item, as SharedPacketItemMatcher does in the app.
        var groups: [[OpenedPacket]] = []
        for packet in packets {
            let item = packet.contents.manifest.item
            if let index = groups.firstIndex(where: { ImportedItemResolver.canRepresentSameWork(item, $0[0].contents.manifest.item) }) {
                groups[index].append(packet)
            } else {
                groups.append([packet])
            }
        }
        let groupOfDigest = Dictionary(
            groups.enumerated().flatMap { index, group in group.map { ($0.digest, index) } },
            uniquingKeysWith: { first, _ in first }
        )

        for (index, group) in groups.enumerated() {
            let title = group[0].contents.manifest.item.title ?? "untitled item"
            report.lines.append("Item \(index + 1): \(title) (\(group.count) packet(s))")
            if Set(group.map(\.digest)).count < group.count {
                report.note("the same packet is listed twice; the second import must be a duplicate")
            }
            for packet in group {
                for (scopedId, links) in packet.contents.conversations.first?.linksByPackageScopedId ?? [:] {
                    for link in links {
                        if let parentGroup = groupOfDigest[link.parentPackageDigest], parentGroup != index {
                            report.fail("\(packet.url.lastPathComponent) \(scopedId) replies to a Margin on a different item")
                        } else if groupOfDigest[link.parentPackageDigest] == nil {
                            report.note("\(packet.url.lastPathComponent) \(scopedId) replies to a packet not in this check; it stays unlinked until that packet arrives")
                        }
                    }
                }
            }
            try checkOrders(group, report: &report)
            noteResentMargins(group, report: &report)
        }
        return report
    }

    private static func checkMapPacket(_ packet: OpenedPacket, url: URL, report: inout Report) {
        let name = url.lastPathComponent
        let scenes = ListeningMapPacket.proposal(in: packet.contents)?.scenes.count ?? 0
        report.pass("\(name): current reader reads a map of \(scenes) chapter(s) and no Margins")
        do {
            let shipped = try ShippedPacketReader.importedMargins(at: url)
            report.fail("\(name): Build 29 imported it (\(shipped.count) Margin(s)); it should refuse a map-only packet")
        } catch {
            if "\(error)".contains("unsupportedRequiredCapability") {
                report.pass("\(name): Build 29 refuses it as needing a newer version, as intended")
            } else {
                report.fail("\(name): Build 29 refused it for another reason: \(error)")
            }
        }
    }

    /// A sender who shares again after adding Margins sends the earlier ones in a new packet. The
    /// importer keeps one copy of each (#858): this reports the re-sends it found, and `checkOrders`
    /// fails if a copy is kept for any of them.
    private static func noteResentMargins(_ group: [OpenedPacket], report: inout Report) {
        var packetsByMargin: [ImportedMarginResends.CopyKey: Set<String>] = [:]
        for packet in group {
            for margin in packet.margins {
                packetsByMargin[copyKey(packet: packet, margin: margin), default: []].insert(packet.digest)
            }
        }
        let resent = packetsByMargin.filter { $0.value.count > 1 }
        if !resent.isEmpty {
            report.note("\(resent.count) Margin(s) arrive in more than one packet (a sender who shared again); each should be kept once")
        }
    }

    /// Use exactly the importer's fields, including full anchor context, voice duration, reply
    /// relationships and provenance eligibility. No audio decoding is needed to compare metadata.
    private static func copyKey(packet: OpenedPacket, margin: SharedInterjectionPackageRecord) -> ImportedMarginResends.CopyKey {
        let representation = margin.defaultRepresentation
        let asset = packet.contents.manifest.assets.first { $0.id == representation?.assetId }
        let imported = ImportedCommentaryInterjection(
            id: margin.packageScopedId, layerId: "check", packageScopedId: margin.packageScopedId,
            createdAt: margin.createdAt, anchorEvidence: margin.anchor,
            approvedTranscript: representation?.approvedTranscript ?? "", audioDurationMs: asset?.durationMs,
            replyLinks: packet.contents.conversations.first?.linksByPackageScopedId[margin.packageScopedId],
            shareProvenance: representation.flatMap { MarginShareProvenance.token(representationID: $0.id) }
        )
        return ImportedMarginResends.copyKey(packageDigest: packet.digest, sender: packet.contents.manifest.senderDisplayLabel, margin: imported)
    }

    /// How many of each Margin the packets carry at most: a sender who said the same thing twice at one
    /// place keeps both, but never more than one packet held.
    private static func expectedCopies(_ group: [OpenedPacket]) -> [ImportedMarginResends.CopyKey: Int] {
        var expected: [ImportedMarginResends.CopyKey: Int] = [:]
        for packet in group {
            var inPacket: [ImportedMarginResends.CopyKey: Int] = [:]
            for margin in packet.margins { inPacket[copyKey(packet: packet, margin: margin), default: 0] += 1 }
            for (key, count) in inPacket { expected[key] = max(expected[key] ?? 0, count) }
        }
        return expected
    }

    /// What a listener ends up with, named by packet identity so orders can be compared. A Margin a
    /// sender sent in two packets is held once, under whichever packet came first; it is known by both
    /// names, so the packets and Margins are counted by every name and replies by the smallest.
    private struct Outcome: Equatable {
        var packets: Set<String> = []
        var margins: Set<MarginPacketIdentity> = []
        var replies: [MarginPacketIdentity: String] = [:]
        var threads: [String: Set<MarginThreadEdge>] = [:]
        /// How many copies of each Margin are held.
        var copies: [ImportedMarginResends.CopyKey: Int] = [:]
    }

    static func checkOrders(_ group: [OpenedPacket], report: inout Report) throws {
        let orders = importOrders(count: group.count)
        var first: Outcome?
        var firstOrder: [Int] = []
        var mismatches = 0
        for order in orders {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("coop-check-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
            let itemId = "coop-check-item"
            var seen: Set<String> = []
            for position in order {
                let packet = group[position]
                let disposition = try SpokenMarginsPackageImporter.importPackage(packet.contents, itemId: itemId, repository: store)
                let isRepeat = !seen.insert(packet.digest).inserted
                if case .imported = disposition, isRepeat {
                    report.fail("\(packet.url.lastPathComponent) imported twice in order \(order.map { $0 + 1 })")
                    return
                }
            }
            for packet in group {
                guard case .duplicate = try SpokenMarginsPackageImporter.importPackage(packet.contents, itemId: itemId, repository: store) else {
                    report.fail("opening \(packet.url.lastPathComponent) again added a second copy")
                    return
                }
            }
            let outcome = try self.outcome(store: store, itemId: itemId)
            let expected = expectedCopies(group)
            if let extra = outcome.copies.first(where: { $0.value > (expected[$0.key] ?? 0) }) {
                report.fail("order \(order.map { $0 + 1 }) keeps \(extra.value) copies of one Margin that no packet carries more than \(expected[extra.key] ?? 0) time(s): \(extra.key)")
                return
            }
            if let first {
                if outcome != first {
                    mismatches += 1
                    if mismatches == 1 {
                        report.fail("order \(order.map { $0 + 1 }) differs from order \(firstOrder.map { $0 + 1 }): \(describeDifference(first, outcome))")
                    }
                }
            } else {
                first = outcome
                firstOrder = order
            }
        }
        guard let outcome = first else { return }
        let ordersText = orders.count == 1 ? "1 order" : "\(orders.count) orders"
        if mismatches == 0 {
            report.pass("\(ordersText) give the same \(outcome.packets.count) packet(s), \(outcome.margins.count) Margin name(s) on \(outcome.copies.values.reduce(0, +)) held Margin(s), \(outcome.threads.count) thread(s); re-imports add nothing")
        }
        let states = outcome.replies.values
        let linked = states.filter { $0 == "linked" }.count
        let missing = states.filter { $0 == "parent missing" }.count
        let forks = states.filter { $0.hasPrefix("fork") }.count
        if !outcome.replies.isEmpty {
            report.note("replies: \(linked) linked, \(missing) waiting for a parent, \(forks) fork(s)")
        }
        for (conversation, edges) in outcome.threads.sorted(by: { $0.key < $1.key }) {
            report.note("thread \(conversation.suffix(8)): \(edges.count) repl\(edges.count == 1 ? "y" : "ies")")
        }
    }

    private static func outcome(store: SQLiteSessionStore, itemId: String) throws -> Outcome {
        let layers = try store.loadImportedCommentaryLayers(itemId: itemId)
        let margins = try layers.flatMap { layer in
            try store.loadImportedCommentaryInterjections(layerId: layer.id).map { (layer, $0) }
        }
        // Every name a held Margin is known by: its own packet's, and any packet that carried it again.
        let identitiesOfMargin = Dictionary(uniqueKeysWithValues: margins.map { layer, margin in
            (margin.id, [MarginPacketIdentity(packageDigest: layer.packageDigest, packageScopedId: margin.packageScopedId)]
                + (margin.alsoSharedAs ?? []))
        })
        func smallest(_ identities: [MarginPacketIdentity]) -> MarginPacketIdentity? {
            identities.min { ($0.packageDigest, $0.packageScopedId) < ($1.packageDigest, $1.packageScopedId) }
        }
        let graph = MarginReplyGraph.build(localMargins: [], layers: layers, importedMargins: margins.map(\.1))
        func name(_ reference: MarginReference?) -> String {
            guard case .imported(let id)? = reference, let identity = smallest(identitiesOfMargin[id] ?? []) else { return "none" }
            return "\(identity.packageDigest.prefix(8))/\(identity.packageScopedId)"
        }
        var outcome = Outcome()
        let allNames = identitiesOfMargin.values.flatMap { $0 }
        outcome.packets = Set(layers.map(\.packageDigest) + allNames.map(\.packageDigest))
        outcome.margins = Set(allNames)
        outcome.threads = graph.threads
        for (layer, margin) in margins {
            let key = ImportedMarginResends.copyKey(packageDigest: layer.packageDigest, sender: layer.displayLabel, margin: margin)
            outcome.copies[key, default: 0] += 1
        }
        for (reference, state) in graph.states {
            guard case .imported(let id) = reference, let identity = smallest(identitiesOfMargin[id] ?? []) else { continue }
            switch state {
            case .linked: outcome.replies[identity] = "linked"
            case .parentMissing: outcome.replies[identity] = "parent missing"
            // A held copy keeps the link order of whichever packet came first, and the parents are a
            // set (the importer matches them as one), so name them in a fixed order.
            case .fork(let parents): outcome.replies[identity] = "fork " + parents.map { name($0.parent) }.sorted().joined(separator: ",")
            }
        }
        return outcome
    }

    private static func describeDifference(_ a: Outcome, _ b: Outcome) -> String {
        if a.packets != b.packets { return "packets \(a.packets.count) vs \(b.packets.count)" }
        if a.margins != b.margins { return "Margins \(a.margins.count) vs \(b.margins.count)" }
        if a.replies != b.replies { return "reply states differ" }
        return "threads differ"
    }

    /// Every order for up to five packets; otherwise the given order, its reverse and random shuffles.
    private static func importOrders(count: Int) -> [[Int]] {
        let indices = Array(0..<count)
        guard count > 5 else { return permutations(indices) }
        var generator = SystemRandomNumberGenerator()
        return [indices, indices.reversed()] + (0..<118).map { _ in indices.shuffled(using: &generator) }
    }

    private static func permutations(_ values: [Int]) -> [[Int]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[Int]] in
            var rest = values
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }
}
