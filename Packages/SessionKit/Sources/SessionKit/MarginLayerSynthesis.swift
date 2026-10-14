#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Gathers several people's Margins on one item into "hot spots" for a co-op summary (#26, #475).
///
/// Only layers the listener chose, and their own Margins only if chosen, reach the input, so
/// nothing from a layer they left out can reach a summary. Every entry carries a citation id
/// that traces back to the exact Margin, and a model's claims are kept only when they cite ids
/// that exist in the input.
public enum MarginLayerSynthesis {
    /// Margins no more than this far apart in source time share a hot spot.
    public static let hotSpotWindowMs = 45_000
    public static let ownSenderLabel = "you"
    public static let unnamedSenderLabel = "Someone"

    public struct Entry: Codable, Equatable, Sendable {
        public let citationId: String
        public let senderLabel: String
        /// Source time in the listener's copy; nil when the Margin is not placed.
        public let anchorTimeMs: Int?
        public let approvedTranscript: String
        public let createdAt: Date
        /// The imported layer the Margin came from; nil for the listener's own Margins.
        public let layerId: String?
        public let marginId: String
    }

    public struct HotSpot: Equatable, Sendable {
        public let startMs: Int
        public let endMs: Int
        public let entries: [Entry]

        /// Distinct senders in the order they first reacted.
        public var senderLabels: [String] {
            var seen = Set<String>()
            return entries.map(\.senderLabel).filter { seen.insert($0).inserted }
        }
    }

    public struct Input: Codable, Equatable, Sendable {
        public let itemId: String
        /// Placed Margins in source order: time, then sender, then creation time.
        public let placed: [Entry]
        public let notPlaced: [Entry]

        public var entries: [Entry] { placed + notPlaced }

        /// Stable bytes for the model's context and for the provenance digest.
        public func serialized() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        public func digest() throws -> String {
            SHA256.hash(data: try serialized()).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Builds the input from the layers the listener chose. A layer contributes only when it
    /// belongs to the item, is enabled, is not deleted and is in `chosenLayerIds`.
    public static func input(
        itemId: String,
        layers: [ImportedCommentaryLayer],
        interjections: [ImportedCommentaryInterjection],
        chosenLayerIds: Set<String>,
        ownMargins: [Interjection] = [],
        includeOwnMargins: Bool = false
    ) -> Input {
        let included = Dictionary(
            layers.filter { $0.itemId == itemId && $0.isEnabled && $0.deletedAt == nil && chosenLayerIds.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var drafts: [Draft] = interjections.compactMap { margin in
            guard let layer = included[margin.layerId] else { return nil }
            return Draft(
                senderLabel: label(layer.displayLabel),
                anchorTimeMs: placedTime(margin.resolution),
                text: margin.approvedTranscript,
                createdAt: margin.createdAt,
                layerId: layer.id,
                marginId: margin.id
            )
        }
        if includeOwnMargins {
            drafts += ownMargins.filter { $0.itemId == itemId && $0.status == "active" }.map { margin in
                Draft(
                    senderLabel: ownSenderLabel,
                    anchorTimeMs: margin.anchor.mediaTimeMs.flatMap { $0 >= 0 ? $0 : nil },
                    text: margin.displayText ?? margin.cleanedTranscript ?? margin.transcript ?? "",
                    createdAt: margin.createdAt,
                    layerId: nil,
                    marginId: margin.id
                )
            }
        }
        let placed = drafts.filter { $0.anchorTimeMs != nil }.sorted(by: sourceOrder)
        let notPlaced = drafts.filter { $0.anchorTimeMs == nil }.sorted(by: sourceOrder)
        var next = 0
        func cite(_ draft: Draft) -> Entry {
            next += 1
            return draft.entry(citationId: "m\(next)")
        }
        let placedEntries = placed.map(cite)
        return Input(itemId: itemId, placed: placedEntries, notPlaced: notPlaced.map(cite))
    }

    /// Groups placed Margins so every pair in a hot spot is within `hotSpotWindowMs`: a spot
    /// closes once the next Margin is further than the window from the spot's first Margin.
    public static func hotSpots(_ input: Input) -> [HotSpot] {
        var spots: [HotSpot] = []
        var current: [Entry] = []
        func close() {
            guard let first = current.first?.anchorTimeMs, let last = current.last?.anchorTimeMs else { return }
            spots.append(HotSpot(startMs: first, endMs: last, entries: current))
            current = []
        }
        for entry in input.placed {
            guard let time = entry.anchorTimeMs else { continue }
            if let start = current.first?.anchorTimeMs, time - start > hotSpotWindowMs { close() }
            current.append(entry)
        }
        close()
        return spots
    }

    /// A plain chronological digest, written without a model, to compare a summary against.
    public static func digest(_ input: Input) -> String {
        var lines: [String] = []
        for spot in hotSpots(input) {
            let count = spot.entries.count == 1 ? "1 Margin" : "\(spot.entries.count) Margins"
            lines.append("Near \(clock(spot.startMs)): \(names(spot.senderLabels)) (\(count))")
            lines += spot.entries.map { "- \($0.senderLabel) [\($0.citationId)]: \($0.approvedTranscript)" }
        }
        if !input.notPlaced.isEmpty {
            lines.append("Not placed:")
            lines += input.notPlaced.map { "- \($0.senderLabel) [\($0.citationId)]: \($0.approvedTranscript)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Checking a model's summary

    public struct ModelClaim: Codable, Equatable, Sendable {
        public let text: String
        public let citationIds: [String]

        public init(text: String, citationIds: [String]) {
            self.text = text
            self.citationIds = citationIds
        }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let modelId: String
        public let promptVersion: String
        public let inputDigest: String
    }

    public struct CheckedClaim: Equatable, Sendable {
        public enum Status: String, Equatable, Sendable { case cited, uncited }
        public let text: String
        public let citationIds: [String]
        public let status: Status
    }

    public struct CheckedSummary: Equatable, Sendable {
        public let claims: [CheckedClaim]
        /// Claims citing an id that isn't in the input. Never shown as part of the summary.
        public let dropped: [ModelClaim]
        public let provenance: Provenance
    }

    public static func check(
        _ claims: [ModelClaim],
        against input: Input,
        modelId: String,
        promptVersion: String
    ) throws -> CheckedSummary {
        let known = Set(input.entries.map(\.citationId))
        var kept: [CheckedClaim] = []
        var dropped: [ModelClaim] = []
        for claim in claims {
            let ids = claim.citationIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if ids.isEmpty {
                kept.append(CheckedClaim(text: claim.text, citationIds: [], status: .uncited))
            } else if ids.allSatisfy(known.contains) {
                kept.append(CheckedClaim(text: claim.text, citationIds: ids, status: .cited))
            } else {
                dropped.append(claim)
            }
        }
        return CheckedSummary(
            claims: kept,
            dropped: dropped,
            provenance: Provenance(modelId: modelId, promptVersion: promptVersion, inputDigest: try input.digest())
        )
    }

    // MARK: Helpers

    private struct Draft {
        let senderLabel: String
        let anchorTimeMs: Int?
        let text: String
        let createdAt: Date
        let layerId: String?
        let marginId: String

        func entry(citationId: String) -> Entry {
            Entry(
                citationId: citationId,
                senderLabel: senderLabel,
                anchorTimeMs: anchorTimeMs,
                approvedTranscript: text,
                createdAt: createdAt,
                layerId: layerId,
                marginId: marginId
            )
        }
    }

    /// Time, then sender, then creation time; the layer and Margin ids break any remaining tie
    /// so shuffled input always gives the same order.
    private static func sourceOrder(_ a: Draft, _ b: Draft) -> Bool {
        if a.anchorTimeMs != b.anchorTimeMs { return (a.anchorTimeMs ?? .max) < (b.anchorTimeMs ?? .max) }
        if a.senderLabel != b.senderLabel { return a.senderLabel < b.senderLabel }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        if a.layerId != b.layerId { return (a.layerId ?? "") < (b.layerId ?? "") }
        return a.marginId < b.marginId
    }

    /// The listener's copy has a position for the Margin. Ambiguous or missing matches are not
    /// placed, even when the sender's time is known. Approximate positions (a map interpolation)
    /// are placed, since that is where the listener hears the Margin play.
    static func placedTime(_ resolution: ImportedAnchorResolution) -> Int? {
        guard !resolution.isAmbiguous, let time = resolution.localMediaTimeMs, time >= 0 else { return nil }
        switch resolution.evidenceClass {
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused, .recipientConfirmed,
             .mapInterpolated, .timestampFallback:
            return time
        case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return nil
        }
    }

    public static func label(_ displayLabel: String?) -> String {
        let trimmed = displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unnamedSenderLabel : trimmed
    }

    private static func names(_ labels: [String]) -> String {
        // "you" reads last: "Ana, Ben and you".
        let ordered = labels.filter { $0 != ownSenderLabel } + labels.filter { $0 == ownSenderLabel }
        guard ordered.count > 1 else { return ordered.first ?? "" }
        return ordered.dropLast().joined(separator: ", ") + " and " + ordered[ordered.count - 1]
    }

    /// `12:40` or `1:01:40`, for hot-spot times.
    public static func clock(_ ms: Int) -> String {
        let total = ms / 1_000
        let hours = total / 3_600, minutes = (total % 3_600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
