import Foundation

/// A friend who shares again after adding Margins sends the earlier ones too, in a packet with a new
/// digest (#858). Each packet used to become its own layer, so the listener kept a second copy of every
/// Margin the friend had already sent.
///
/// Cross-packet matching requires stable capture provenance. Display labels, matching words and
/// locations cannot establish that two people are the same sender. Legacy packets without that
/// provenance are imported whole. New exports use a Build-29-compatible representation ID.
/// Held Margins retain their layer, heard state and replies; later packet names become aliases.
public enum ImportedMarginResends {
    /// What identifies a Margin across one sender's packets.
    struct Fingerprint: Hashable {
        let transcript: String
        let anchor: String
        let audioDurationMs: Int?
        let shareProvenance: String?
        let replyLinks: Set<MarginReplyLink>

        init(_ margin: ImportedCommentaryInterjection) {
            transcript = margin.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            // The ids of the sender's acoustic signatures are named per export; the place isn't.
            let place = PortableAnchorEvidence(
                anchorType: margin.anchorEvidence.anchorType,
                startChar: margin.anchorEvidence.startChar,
                endChar: margin.anchorEvidence.endChar,
                exactText: margin.anchorEvidence.exactText?.precomposedStringWithCanonicalMapping,
                prefix: margin.anchorEvidence.prefix?.precomposedStringWithCanonicalMapping,
                suffix: margin.anchorEvidence.suffix?.precomposedStringWithCanonicalMapping,
                mediaTimeMs: margin.anchorEvidence.mediaTimeMs,
                roughPercent: margin.anchorEvidence.roughPercent,
                transcriptSegmentId: margin.anchorEvidence.transcriptSegmentId?.precomposedStringWithCanonicalMapping,
                chapterTitle: margin.anchorEvidence.chapterTitle?.precomposedStringWithCanonicalMapping
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            anchor = (try? encoder.encode(place)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            audioDurationMs = margin.audioDurationMs
            shareProvenance = margin.shareProvenance
            replyLinks = Set(margin.replyLinks ?? [])
        }
    }

    /// One equivalence rule for both the importer and coop-packet check. Ineligible Margins are
    /// unique to their packet; a checker must not call ambiguous legacy Margins duplicate copies.
    public struct CopyKey: Hashable {
        let sender: String
        let fingerprint: Fingerprint
        let packetIdentity: MarginPacketIdentity?
    }

    public static func copyKey(packageDigest: String, sender: String?, margin: ImportedCommentaryInterjection) -> CopyKey {
        let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eligible = !sender.isEmpty && margin.shareProvenance.map(MarginShareProvenance.isValidToken) == true
        return CopyKey(sender: sender, fingerprint: Fingerprint(margin), packetIdentity: eligible ? nil :
            MarginPacketIdentity(packageDigest: packageDigest, packageScopedId: margin.packageScopedId))
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
        for entry in held where entry.margin.shareProvenance.map(MarginShareProvenance.isValidToken) == true {
            heldByFingerprint[Fingerprint(entry.margin), default: []].append(entry)
        }
        var plan = Plan(newMargins: [], identitiesByHeldMargin: [:], firstHeldLayerId: nil)
        for margin in incoming {
            let fingerprint = Fingerprint(margin)
            guard margin.shareProvenance.map(MarginShareProvenance.isValidToken) == true,
                  var candidates = heldByFingerprint[fingerprint], !candidates.isEmpty else {
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

    /// Artifact-only layers still need the app's podcast placement pass after commentary deduplication.
    public static func hasLayerArtifacts(_ layer: ImportedCommentaryLayer) -> Bool {
        !(layer.listeningMapProposals ?? []).isEmpty
            || !(layer.editionFingerprintSpines ?? []).isEmpty
            || !(layer.transcriptPhraseSketches ?? []).isEmpty
            || !(layer.episodeMapEvidencePaths ?? [:]).isEmpty
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
        // Even with no new commentary, save a layer that carries map/placement artifacts. The app
        // resolves maps from these layer fields, independently of its list of Margins.
        guard !plan.newMargins.isEmpty || hasLayerArtifacts(layer) else { return .duplicate(existingLayerId: heldLayerId) }
        return try repository.importCommentaryLayer(layer, interjections: plan.newMargins)
    }
}
