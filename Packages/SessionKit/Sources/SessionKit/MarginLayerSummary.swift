#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The prompt, the reply parser and the on-device record for the co-op "Where people reacted"
/// summary (#476). The model call itself lives in the app; everything here runs on the host.
extension MarginLayerSynthesis {
    public static let promptVersion = "reactions.v1"
    /// Per-Margin and whole-prompt caps keep the prompt inside the on-device model's context window.
    public static let promptEntryCharacterLimit = 320
    public static let promptCharacterLimit = 9_000

    /// "Where people reacted" is offered when the item carries Margins from at least two senders:
    /// each enabled imported layer that has a Margin counts as one, and the listener's own count as one.
    public static func offersReactions(
        itemId: String,
        layers: [ImportedCommentaryLayer],
        interjections: [String: [ImportedCommentaryInterjection]],
        ownMargins: [Interjection]
    ) -> Bool {
        let senders = layers.filter { $0.itemId == itemId && $0.isEnabled && $0.deletedAt == nil }
            .filter { !(interjections[$0.id] ?? []).isEmpty }.count
        let own = ownMargins.contains { $0.itemId == itemId && $0.status == "active" } ? 1 : 0
        return senders + own >= 2
    }

    /// The prompt for the on-device model. It lists the placed Margins in source order, each with its
    /// citation id, and asks for one cited sentence per line. Not-placed Margins are left out: the
    /// summary is about where people reacted.
    public static func prompt(for input: Input) -> String {
        var lines: [String] = []
        var size = 0
        for entry in input.placed {
            guard let time = entry.anchorTimeMs else { continue }
            let text = entry.approvedTranscript.split(whereSeparator: \.isNewline).joined(separator: " ")
            let line = "[\(entry.citationId)] \(entry.senderLabel) at \(clock(time)): \(String(text.prefix(promptEntryCharacterLimit)))"
            if size + line.count > promptCharacterLimit { break }
            size += line.count
            lines.append(line)
        }
        return """
        Several listeners left spoken Margins on the same item. Summarize where they reacted and what they said.
        Write 2 to 5 short sentences, one per line. End every sentence with the ids of the Margins it comes from, in square brackets, like [m1][m3].
        Use only what the Margins say. Name who said what. Never add facts, opinions or quotes that are not in the Margins. Cite only ids listed below.

        \(lines.joined(separator: "\n"))
        """
    }

    /// Reads the model's reply into claims. A line's citations are the `[m1]` or `[m1, m3]` groups in it;
    /// they are removed from the claim text. A line with none becomes an uncited claim, which the
    /// validator marks and the screen never shows.
    public static func parseClaims(_ output: String) -> [ModelClaim] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-•*".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { return nil }
            var text = ""
            var ids: [String] = []
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == "[", let close = line[index...].firstIndex(of: "]") {
                    let inside = line[line.index(after: index)..<close]
                    let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map { $0.lowercased() }
                    if !parts.isEmpty, parts.allSatisfy(isCitationId) {
                        ids += parts
                        index = line.index(after: close)
                        continue
                    }
                }
                text.append(line[index])
                index = line.index(after: index)
            }
            let claim = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !claim.isEmpty else { return nil }
            var seen = Set<String>()
            return ModelClaim(text: claim, citationIds: ids.filter { seen.insert($0).inserted })
        }
    }

    private static func isCitationId(_ value: String) -> Bool {
        value.count >= 2 && value.first == "m" && value.dropFirst().allSatisfy(\.isNumber)
    }
}

/// A summary kept on the phone, with where it came from. It is never part of a packet, a Markdown
/// export or a JSON export: it lives in its own file, outside the database, and no export reads it.
public struct StoredReactionSummary: Codable, Equatable, Sendable {
    public struct Claim: Codable, Equatable, Sendable {
        public let text: String
        public let citationIds: [String]
    }

    /// Where a citation id points, kept so a citation still opens its Margin after the screen is reopened.
    public struct Citation: Codable, Equatable, Sendable {
        public let citationId: String
        public let senderLabel: String
        public let anchorTimeMs: Int?
        public let layerId: String?
        public let marginId: String
    }

    public let itemId: String
    public let generatedAt: Date
    public let provenance: MarginLayerSynthesis.Provenance
    public let claims: [Claim]
    public let citations: [Citation]

    /// Keeps only claims that cite Margins in the input; uncited and unknown-id claims never reach it.
    public init(itemId: String, generatedAt: Date, input: MarginLayerSynthesis.Input, checked: MarginLayerSynthesis.CheckedSummary) {
        self.itemId = itemId
        self.generatedAt = generatedAt
        self.provenance = checked.provenance
        let claims = checked.claims.filter { $0.status == .cited }
        self.claims = claims.map { Claim(text: $0.text, citationIds: $0.citationIds) }
        let used = Set(claims.flatMap(\.citationIds))
        self.citations = input.entries.filter { used.contains($0.citationId) }.map {
            Citation(citationId: $0.citationId, senderLabel: $0.senderLabel, anchorTimeMs: $0.anchorTimeMs,
                     layerId: $0.layerId, marginId: $0.marginId)
        }
    }

    /// True when a Margin it cites is gone (its layer was deleted, or the Margin was). Words drawn from
    /// someone's removed Margin must not stay on the phone, so the owner of the store deletes it.
    public func isOrphaned(liveMarginIds: Set<String>) -> Bool {
        citations.contains { !liveMarginIds.contains($0.marginId) }
    }

    /// True when the Margins that would feed a summary now differ from the ones it was written from.
    public func isStale(for input: MarginLayerSynthesis.Input) -> Bool {
        (try? input.digest()) != provenance.inputDigest
    }
}

/// One JSON file per item, replaced on the next run. Build 29 never reads this folder.
public struct ReactionSummaryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(itemId: String) -> StoredReactionSummary? {
        guard let data = try? Data(contentsOf: fileURL(itemId: itemId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let summary = try? decoder.decode(StoredReactionSummary.self, from: data), summary.itemId == itemId else { return nil }
        return summary
    }

    public func all() -> [StoredReactionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(StoredReactionSummary.self, from: $0) }
        }
    }

    public func save(_ summary: StoredReactionSummary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: fileURL(itemId: summary.itemId), options: .atomic)
    }

    public func delete(itemId: String) {
        try? FileManager.default.removeItem(at: fileURL(itemId: itemId))
    }

    func fileURL(itemId: String) -> URL {
        let name = SHA256.hash(data: Data(itemId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}
