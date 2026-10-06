import Foundation

/// A friend who shares again after adding Margins sends the earlier ones too, in a packet with a new
/// digest (#858). Each packet used to become its own layer, so the listener kept a second copy of every
/// Margin the friend had already sent.
///
/// A packet carries no sender identity (signing is #22), so "the same Margin" is judged from what the
/// packet does carry. Neither the packet's Margin id (`margin-0004` counts the Margins in that packet,
/// so it shifts when the friend deletes one) nor the packet's created time (the moment of sharing)
/// survives a re-share. What does is the sender's label together with the Margin's words, its place
/// in the source and its voice length. Two different people who share a label also have to agree on
/// all of those before one Margin hides the other.
///
/// Nothing is deleted or rewritten: the Margins the listener already holds stay, with their layer,
/// their heard state and the replies pointing at them. A Margin that arrives again is not stored a
/// second time. Its packet identity is recorded on the held copy (`alsoSharedAs`), so a reply that
/// names the newer packet still finds its parent. The outcome is the same whichever packet arrives
/// first, because the Margins are the same and each is held once.
public enum ImportedMarginResends {
    /// What identifies a Margin across one sender's packets.
    struct Fingerprint: Hashable {
        let transcript: String
        let anchor: String
        let audioDurationMs: Int?

        init(_ margin: ImportedCommentaryInterjection) {
            transcript = margin.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            // The ids of the sender's acoustic signatures are named per export; the place isn't.
            let place = PortableAnchorEvidence(
                anchorType: margin.anchorEvidence.anchorType,
                startChar: margin.anchorEvidence.startChar,
                endChar: margin.anchorEvidence.endChar,
                exactText: margin.anchorEvidence.exactText,
                prefix: margin.anchorEvidence.prefix,
                suffix: margin.anchorEvidence.suffix,
                mediaTimeMs: margin.anchorEvidence.mediaTimeMs,
                roughPercent: margin.anchorEvidence.roughPercent,
                transcriptSegmentId: margin.anchorEvidence.transcriptSegmentId,
                chapterTitle: margin.anchorEvidence.chapterTitle
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            anchor = (try? encoder.encode(place)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            audioDurationMs = margin.audioDurationMs
        }
    }

    public struct Plan: Equatable, Sendable {
        /// The packet's Margins the listener doesn't hold yet, in packet order.
        public var newMargins: [ImportedCommentaryInterjection]
        /// Held Margins the packet carries again, with the identities that packet gives them.
        public var identitiesByHeldMargin: [String: [MarginPacketIdentity]]
        /// The layer holding the first Margin the packet carries again, if any.
        public var firstHeldLayerId: String?
    }

    /// Splits a packet's Margins into new ones and ones already held. `held` is every Margin of the
    /// same sender on the same item, oldest first; each held Margin answers for at most one of the
    /// packet's Margins, so a sender who really did say the same thing twice at the same place keeps both.
    public static func plan(
        packageDigest: String,
        incoming: [ImportedCommentaryInterjection],
        held: [(layerId: String, margin: ImportedCommentaryInterjection)]
    ) -> Plan {
        var heldByFingerprint: [Fingerprint: [(layerId: String, margin: ImportedCommentaryInterjection)]] = [:]
        for entry in held { heldByFingerprint[Fingerprint(entry.margin), default: []].append(entry) }
        var plan = Plan(newMargins: [], identitiesByHeldMargin: [:], firstHeldLayerId: nil)
        for margin in incoming {
            let fingerprint = Fingerprint(margin)
            guard var candidates = heldByFingerprint[fingerprint], !candidates.isEmpty else {
                plan.newMargins.append(margin)
                continue
            }
            let match = candidates.removeFirst()
            heldByFingerprint[fingerprint] = candidates
            plan.identitiesByHeldMargin[match.margin.id, default: []].append(
                MarginPacketIdentity(packageDigest: packageDigest, packageScopedId: margin.packageScopedId)
            )
            if plan.firstHeldLayerId == nil { plan.firstHeldLayerId = match.layerId }
        }
        return plan
    }

    /// Imports a packet's layer, leaving out the Margins this sender already gave the listener on this item.
    /// Call it where the layer would otherwise go to `importCommentaryLayer`.
    public static func importLayer(
        _ layer: ImportedCommentaryLayer,
        interjections: [ImportedCommentaryInterjection],
        repository: ListeningSessionRepository
    ) throws -> ImportedCommentaryImportDisposition {
        let sender = layer.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Without a sender, or without the item they landed on, there is nobody to compare against.
        guard !sender.isEmpty, let itemId = layer.itemId,
              try repository.loadImportedCommentaryLayer(packageDigest: layer.packageDigest) == nil else {
            return try repository.importCommentaryLayer(layer, interjections: interjections)
        }
        // A layer the listener deleted doesn't absorb a re-share, and neither does one whose source
        // didn't match: its Margins never play.
        let layers = try repository.loadImportedCommentaryLayers(itemId: itemId).filter {
            $0.deletedAt == nil && $0.sourceResolutionStatus != .wrongSource
                && $0.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) == sender
        }
        var held: [(layerId: String, margin: ImportedCommentaryInterjection)] = []
        for heldLayer in layers {
            for margin in try repository.loadImportedCommentaryInterjections(layerId: heldLayer.id) {
                held.append((heldLayer.id, margin))
            }
        }
        let plan = plan(packageDigest: layer.packageDigest, incoming: interjections, held: held)
        guard let heldLayerId = plan.firstHeldLayerId else {
            return try repository.importCommentaryLayer(layer, interjections: interjections)
        }
        // Record the identities first. If the import below then fails, the held Margins merely know a
        // packet name they would have been given anyway; the other order could leave a reply orphaned.
        for entry in held {
            guard let identities = plan.identitiesByHeldMargin[entry.margin.id] else { continue }
            var margin = entry.margin
            margin.alsoSharedAs = (margin.alsoSharedAs ?? []) + identities.filter { !(margin.alsoSharedAs ?? []).contains($0) }
            try repository.saveImportedCommentaryInterjection(margin)
        }
        guard !plan.newMargins.isEmpty else { return .duplicate(existingLayerId: heldLayerId) }
        return try repository.importCommentaryLayer(layer, interjections: plan.newMargins)
    }
}
