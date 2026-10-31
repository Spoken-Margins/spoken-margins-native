import Foundation
import SessionKit

public enum InterjectionPackagePreparationError: Error, Equatable, LocalizedError {
    case unapprovedRevision(String)
    case emptyApprovedTranscript(String)
    case cleanedAudioUnavailable(String)
    case cleanedAudioMismatch(String)
    case duplicatePackageScopedId(String)
    case invalidLocalIdentity(String)
    case missingVerifiedDigest

    public var errorDescription: String? {
        switch self {
        case .unapprovedRevision(let id): return "Share revision \(id) has not been sender-approved."
        case .emptyApprovedTranscript(let id): return "Share revision \(id) has no approved transcript."
        case .cleanedAudioUnavailable(let id): return "Share revision \(id) has no reviewed cleaned audio."
        case .cleanedAudioMismatch(let id): return "Selected audio does not belong to share revision \(id)."
        case .duplicatePackageScopedId(let id): return "Package-scoped interjection ID is duplicated: \(id)."
        case .invalidLocalIdentity(let id): return "Recipient-local identity is not distinct: \(id)."
        case .missingVerifiedDigest: return "A package must pass archive digest verification before import."
        }
    }
}

public enum ReviewedRepresentationSelection: Sendable {
    case textOnly
    case originalAudio(sourceURL: URL, durationMs: Int)
    case cleanedAudio(sourceURL: URL)
}

public struct ReviewedInterjectionSelection: Sendable {
    public let packageScopedId: String
    public let revision: InterjectionShareRevision
    public let anchor: PortableAnchorEvidence
    public let representation: ReviewedRepresentationSelection
    /// The Margin's `replyTo` when it answers someone's shared Margin (#472).
    public let replyTo: MarginReplyLink?

    public init(
        packageScopedId: String,
        revision: InterjectionShareRevision,
        anchor: PortableAnchorEvidence,
        representation: ReviewedRepresentationSelection,
        replyTo: MarginReplyLink? = nil
    ) {
        self.packageScopedId = packageScopedId
        self.revision = revision
        self.anchor = anchor
        self.representation = representation
        self.replyTo = replyTo
    }
}

public struct ReviewedMachineEvidenceAsset: Sendable {
    public let id: String
    public let path: String
    public let sourceURL: URL
    public let durationMs: Int
    public let anchorOffsetMs: Int
    public let provenance: String

    public init(
        id: String,
        path: String,
        sourceURL: URL,
        durationMs: Int,
        anchorOffsetMs: Int,
        provenance: String = PodcastAnchorEvidenceProvenance.exactLocalPlaybackEdition.rawValue
    ) {
        self.id = id
        self.path = path
        self.sourceURL = sourceURL
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
        self.provenance = provenance
    }
}

public enum ReviewedItemTransportSelection: Sendable {
    case reference
    case recipientSupplied
    case embeddedText(text: String, originalMediaType: String, rightsBasis: SharedItemRightsBasis)
}

public enum SpokenMarginsPackageBuilder {
    /// Longer than any real page address. A longer identity link is left out rather than fill the manifest (#2118).
    public static let maximumLinkCharacters = 2_000

    /// `localSourceTexts` are the item's own text on this device and an episode's transcript when it
    /// has one. They are never written into the packet, so map proposals are checked against the whole
    /// of each (except the embedded text, which is checked as the packet carries it): a scene summary,
    /// title or reason quoting any part of the source is dropped even when the source goes by reference.
    public static func prepare(
        packageId: String,
        createdAt: Date,
        item: SharedItemIdentity,
        itemTransportSelection: ReviewedItemTransportSelection,
        selections: [ReviewedInterjectionSelection],
        mapProposals: [PortableListeningMapProposalArtifact] = [],
        localSourceTexts: [String] = [],
        fingerprintSpines: [EditionFingerprintSpineArtifact] = [],
        phraseSketches: [TranscriptPhraseSketchArtifact] = [],
        machineEvidence: [ReviewedMachineEvidenceAsset] = [],
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil
    ) throws -> PreparedSpokenMarginsPackage {
        let item = removingPrivateLinks(from: item)
        // Each signature may back one landmark across all spines: Build 29's importer keys a dictionary
        // by signature and traps on a repeat.
        var unusedSignatureAssetIDs = Set(machineEvidence.map(\.id))
        let fingerprintSpines = fingerprintSpines.map(removingPrivateLinks(from:)).compactMap { spine in
            let repaired = FingerprintSpineExportRepair.repaired(spine, item: item, signatureAssetIDs: unusedSignatureAssetIDs)
            unusedSignatureAssetIDs.subtract(repaired?.landmarks.map(\.signatureAssetId) ?? [])
            return repaired
        }
        // The manifest lists one descriptor per signature, so pack only those a Margin or a kept landmark names, once
        // each: a long-heard episode's spine is spread to 500 landmarks, but every stored one's signature was packed (#2118).
        let namedSignatureIDs = Set(selections.flatMap { $0.anchor.machineEvidenceAssetIds })
            .union(fingerprintSpines.flatMap { $0.landmarks.map(\.signatureAssetId) })
        var packedSignatureIDs = Set<String>()
        let machineEvidence = machineEvidence.filter {
            namedSignatureIDs.contains($0.id) && packedSignatureIDs.insert($0.id).inserted
        }
        let scopedIds = selections.map(\.packageScopedId)
        if let duplicate = Dictionary(grouping: scopedIds, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw InterjectionPackagePreparationError.duplicatePackageScopedId(duplicate)
        }

        var records: [SharedInterjectionPackageRecord] = []
        var assetFiles: [String: URL] = [:]
        var assets: [SpokenMarginsAssetDescriptor] = []
        for (index, selection) in selections.enumerated() {
            let revision = selection.revision
            guard revision.status == .senderApproved else {
                throw InterjectionPackagePreparationError.unapprovedRevision(revision.id)
            }
            let approvedTranscript = revision.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !approvedTranscript.isEmpty else {
                throw InterjectionPackagePreparationError.emptyApprovedTranscript(revision.id)
            }

            let provenance = MarginShareProvenance.token(sessionId: revision.sessionId, interjectionId: revision.interjectionId)
            let representation: SharedInterjectionRepresentation
            switch selection.representation {
            case .textOnly:
                representation = SharedInterjectionRepresentation(
                    id: MarginShareProvenance.representationID(token: provenance, kind: "text", fallback: String(format: "representation-%04d-text", index + 1)),
                    kind: .textOnly,
                    approvedTranscript: approvedTranscript,
                    provenance: .senderApprovedTextOnly
                )
            case .originalAudio(let sourceURL, let durationMs):
                guard durationMs > 0, durationMs <= 600_000 else {
                    throw InterjectionPackagePreparationError.cleanedAudioUnavailable(revision.id)
                }
                let assetID = String(format: "asset-%04d-original", index + 1)
                let archivePath = String(format: "assets/audio/margin-%04d-original.m4a", index + 1)
                assetFiles[archivePath] = sourceURL
                assets.append(SpokenMarginsAssetDescriptor(
                    id: assetID,
                    role: SpokenMarginsAssetRole.originalVoice,
                    path: archivePath,
                    mimeType: "audio/mp4",
                    durationMs: durationMs,
                    provenance: SharedInterjectionProvenance.senderApprovedOriginal.rawValue
                ))
                representation = SharedInterjectionRepresentation(
                    id: MarginShareProvenance.representationID(token: provenance, kind: "original", fallback: String(format: "representation-%04d-original", index + 1)),
                    kind: .originalAudioAndText,
                    approvedTranscript: approvedTranscript,
                    assetId: assetID,
                    provenance: .senderApprovedOriginal
                )
            case .cleanedAudio(let sourceURL):
                guard let cleanedAudioPath = revision.cleanedAudioPath,
                      let duration = revision.cleanedAudioDurationMs else {
                    throw InterjectionPackagePreparationError.cleanedAudioUnavailable(revision.id)
                }
                let revisionURL = URL(fileURLWithPath: cleanedAudioPath).standardizedFileURL
                guard revisionURL == sourceURL.standardizedFileURL else {
                    throw InterjectionPackagePreparationError.cleanedAudioMismatch(revision.id)
                }
                let assetID = String(format: "asset-%04d-cleaned", index + 1)
                let archivePath = String(format: "assets/audio/margin-%04d-cleaned.m4a", index + 1)
                assetFiles[archivePath] = sourceURL
                assets.append(SpokenMarginsAssetDescriptor(
                    id: assetID,
                    role: SpokenMarginsAssetRole.cleanedVoice,
                    path: archivePath,
                    mimeType: "audio/mp4",
                    durationMs: duration,
                    provenance: SharedInterjectionProvenance.deterministicCleanupV1SenderApproved.rawValue
                ))
                representation = SharedInterjectionRepresentation(
                    id: MarginShareProvenance.representationID(token: provenance, kind: "cleaned", fallback: String(format: "representation-%04d-cleaned", index + 1)),
                    kind: .cleanedAudioAndText,
                    approvedTranscript: approvedTranscript,
                    assetId: assetID,
                    provenance: .deterministicCleanupV1SenderApproved
                )
            }
            records.append(SharedInterjectionPackageRecord(
                packageScopedId: selection.packageScopedId,
                createdAt: revision.createdAt,
                anchor: selection.anchor.bounded(
                    prefix: revision.anchorBefore,
                    suffix: revision.anchorAfter,
                    commentLength: ExcerptCapRule.commentLength(transcript: approvedTranscript)
                ),
                defaultRepresentationId: representation.id,
                representations: [representation]
            ))
        }

        for evidence in machineEvidence {
            assetFiles[evidence.path] = evidence.sourceURL
            assets.append(SpokenMarginsAssetDescriptor(
                id: evidence.id,
                role: SpokenMarginsAssetRole.acousticSignature,
                path: evidence.path,
                mimeType: "application/vnd.apple.shazam.signature",
                durationMs: evidence.durationMs,
                anchorOffsetMs: evidence.anchorOffsetMs,
                provenance: evidence.provenance
            ))
        }

        let commentary = SharedCommentaryLayerArtifact(
            id: "commentary-layer",
            interjections: records
        )
        let commentaryPath = "artifacts/commentary-layer.json"
        var artifactData = [commentaryPath: try encodeArtifact(commentary)]
        var artifacts = [SpokenMarginsArtifactDescriptor(
            id: commentary.id,
            kind: SpokenMarginsArtifactKind.commentaryLayer,
            schemaVersion: commentary.schemaVersion,
            path: commentaryPath,
            required: true
        )]
        // The on-device labeller describes every scene, and a Listening Edition's summaries come from
        // outside the app, so drop what breaks the scene rules rather than refuse the Margins (#480).
        var embeddedItemText: String?
        if case .embeddedText(let text, _, _) = itemTransportSelection { embeddedItemText = text }
        // Text the packet doesn't carry is checked whole: a quotation of any part of it would leak it.
        var mapProposals = PortableListeningMapContract.forSharing(
            mapProposals, sourceTexts: [embeddedItemText].compactMap { $0 },
            withheldTexts: localSourceTexts.filter { $0 != embeddedItemText })
        // Shared by reference, the packet carries none of the item's text, so its map anchors don't quote it.
        if embeddedItemText == nil {
            mapProposals = mapProposals.map(PortableListeningMapContract.withoutLongAnchorQuotations)
        }
        for (index, proposal) in mapProposals.enumerated() {
            let path = String(format: "artifacts/listening-map-proposal-%04d.json", index + 1)
            artifactData[path] = try encodeArtifact(proposal)
            artifacts.append(SpokenMarginsArtifactDescriptor(
                id: proposal.id,
                kind: SpokenMarginsArtifactKind.listeningMapProposal,
                schemaVersion: proposal.schemaVersion,
                path: path,
                required: false
            ))
        }
        for (index, spine) in fingerprintSpines.enumerated() {
            let path = String(format: "artifacts/edition-fingerprint-spine-%04d.json", index + 1)
            artifactData[path] = try encodeArtifact(spine)
            artifacts.append(SpokenMarginsArtifactDescriptor(
                id: spine.id,
                kind: SpokenMarginsArtifactKind.editionFingerprintSpine,
                schemaVersion: spine.schemaVersion,
                path: path,
                required: false
            ))
        }
        for (index, sketch) in phraseSketches.enumerated() {
            let path = String(format: "artifacts/transcript-phrase-sketch-%04d.json", index + 1)
            artifactData[path] = try encodeArtifact(sketch)
            artifacts.append(SpokenMarginsArtifactDescriptor(
                id: sketch.id,
                kind: SpokenMarginsArtifactKind.transcriptPhraseSketch,
                schemaVersion: sketch.schemaVersion,
                path: path,
                required: false
            ))
        }

        let itemTransport: SharedItemTransport
        let fullItemOmitted: Bool
        switch itemTransportSelection {
        case .reference where item.canonicalURL == nil:
            // The only link was private, so the recipient supplies the item from their own copy.
            itemTransport = SharedItemTransport(kind: .recipientSupplied)
            fullItemOmitted = true
        case .reference:
            itemTransport = SharedItemTransport(kind: .reference)
            fullItemOmitted = true
        case .recipientSupplied:
            itemTransport = SharedItemTransport(kind: .recipientSupplied)
            fullItemOmitted = true
        case .embeddedText(let text, let originalMediaType, let rightsBasis):
            let embedded = EmbeddedTextItemArtifact(
                originalMediaType: originalMediaType,
                text: text
            )
            let path = "artifacts/embedded-item.json"
            artifactData[path] = try encodeArtifact(embedded)
            artifacts.append(SpokenMarginsArtifactDescriptor(
                id: embedded.id,
                kind: SpokenMarginsArtifactKind.embeddedTextItem,
                schemaVersion: embedded.schemaVersion,
                path: path,
                required: true
            ))
            itemTransport = SharedItemTransport(
                kind: .embeddedText,
                embeddedArtifactId: embedded.id,
                rightsBasis: rightsBasis
            )
            fullItemOmitted = false
        }

        // Only a packet with a reply gets the artifact, so every other packet stays exactly as
        // Build 29 wrote it. It is optional and adds no required capability: Build 29 skips it and
        // imports the replies as ordinary Margins (#472).
        let replies = selections.compactMap { selection in
            selection.replyTo.map { MarginConversationArtifact.Reply(packageScopedId: selection.packageScopedId, link: $0) }
        }
        if !replies.isEmpty {
            let conversation = MarginConversationArtifact(replies: replies)
            let path = "artifacts/margin-conversation.json"
            artifactData[path] = try encodeArtifact(conversation)
            artifacts.append(SpokenMarginsArtifactDescriptor(
                id: conversation.id,
                kind: SpokenMarginsArtifactKind.conversation,
                schemaVersion: conversation.schemaVersion,
                path: path,
                required: false
            ))
        }

        var requiredCapabilities = [SharedCommentaryLayerArtifact.schemaVersion]
        if itemTransport.kind == .embeddedText {
            requiredCapabilities.append(EmbeddedTextItemArtifact.schemaVersion)
        }

        return PreparedSpokenMarginsPackage(
            manifest: SpokenMarginsPackageManifest(
                packageId: packageId,
                createdAt: createdAt,
                item: item,
                itemTransport: itemTransport,
                senderDisplayLabel: senderDisplayLabel,
                suggestedRevealMode: suggestedRevealMode,
                requiredCapabilities: requiredCapabilities,
                artifacts: artifacts,
                assets: assets,
                redactions: InterjectionPackageRedactions(fullItemOmitted: fullItemOmitted)
            ),
            artifactData: artifactData,
            assetFiles: assetFiles
        )
    }

    /// Drops links that could grant access to a private feed (#168). Fields are omitted rather
    /// than renamed so the packet still imports into builds that predate this policy.
    private static func removingPrivateLinks(from item: SharedItemIdentity) -> SharedItemIdentity {
        SharedItemIdentity(
            itemType: item.itemType,
            canonicalURL: shareableLink(item.canonicalURL),
            originalURL: shareableLink(item.originalURL),
            title: item.title,
            author: item.author,
            publisher: item.publisher,
            showTitle: item.showTitle,
            episodeGUID: ShareableLinkPolicy.shareableEpisodeGUID(item.episodeGUID),
            enclosureURL: shareableLink(item.enclosureURL),
            publishedAt: item.publishedAt,
            durationMs: item.durationMs,
            normalizedContentSHA256: item.normalizedContentSHA256,
            exactEditionSHA256: item.exactEditionSHA256,
            languageCode: item.languageCode,
            source: item.source.flatMap { source in
                shareableLink(source.canonicalURL) == nil ? nil : source
            }
        )
    }

    private static func shareableLink(_ link: String?) -> String? {
        ShareableLinkPolicy.shareableLink(link).flatMap { $0.count <= maximumLinkCharacters ? $0 : nil }
    }

    private static func removingPrivateLinks(from spine: EditionFingerprintSpineArtifact) -> EditionFingerprintSpineArtifact {
        EditionFingerprintSpineArtifact(
            id: spine.id,
            schemaVersion: spine.schemaVersion,
            itemId: spine.itemId,
            canonicalURL: shareableLink(spine.canonicalURL),
            episodeGUID: ShareableLinkPolicy.shareableEpisodeGUID(spine.episodeGUID),
            producingEditionDurationMs: spine.producingEditionDurationMs,
            producingEditionSHA256: spine.producingEditionSHA256,
            createdAt: spine.createdAt,
            generatorVersion: spine.generatorVersion,
            landmarks: spine.landmarks
        )
    }

    private static func encodeArtifact<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

public enum SpokenMarginsPackageImporter {
    public typealias LocalIDProvider = (_ kind: String, _ packageScopedID: String) -> String

    public static func importPackage(
        _ contents: VerifiedSpokenMarginsPackage,
        itemId: String? = nil,
        localItem: SharedItemIdentity? = nil,
        itemText: String? = nil,
        importedAt: Date = Date(),
        repository: SessionRepository,
        makeLocalID: LocalIDProvider = defaultLocalID
    ) throws -> ImportedCommentaryImportDisposition {
        let manifest = contents.manifest
        guard let digest = manifest.contentDigest else {
            throw InterjectionPackagePreparationError.missingVerifiedDigest
        }
        guard let commentary = contents.commentaryLayers.first else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("required commentary layer is absent")
        }
        // A map-only packet has no Margins to layer; its map is placed by `TextListeningMapPlacer` instead (#1471).
        guard !ListeningMapPacket.isMapPacket(manifest) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("a listening map packet has no Margins to import")
        }
        let itemResolution = localItem.map {
            ImportedItemResolver.resolve(
                item: manifest.item,
                interjections: commentary.interjections,
                against: $0,
                itemText: itemText
            )
        } ?? ImportedItemResolver.pending(interjections: commentary.interjections)
        let replyLinks = contents.conversations.first?.linksByPackageScopedId ?? [:]
        let layerID = makeLocalID("layer", manifest.packageId)
        let packageIDs = Set([manifest.packageId] + commentary.interjections.map(\.packageScopedId))
        guard !layerID.isEmpty, !packageIDs.contains(layerID) else {
            throw InterjectionPackagePreparationError.invalidLocalIdentity(layerID)
        }
        var generatedIDs: Set<String> = [layerID]
        var importedInterjections: [ImportedCommentaryInterjection] = []
        for record in commentary.interjections {
            let localID = makeLocalID("interjection", record.packageScopedId)
            guard !localID.isEmpty,
                  !packageIDs.contains(localID),
                  generatedIDs.insert(localID).inserted else {
                throw InterjectionPackagePreparationError.invalidLocalIdentity(localID)
            }
            guard let representation = record.defaultRepresentation else {
                throw SpokenMarginsPackageArchiveError.invalidManifest("default representation is absent")
            }
            let asset = representation.assetId.flatMap { assetID in
                manifest.assets.first { $0.id == assetID }
            }
            let podcastEvidence = record.anchor.machineEvidenceAssetIds.compactMap { evidenceID -> ImportedPodcastAnchorEvidence? in
                guard let descriptor = manifest.assets.first(where: { $0.id == evidenceID }),
                      descriptor.role == SpokenMarginsAssetRole.acousticSignature,
                      let localURL = contents.extractedAssetURLs[evidenceID],
                      let anchorOffsetMs = descriptor.anchorOffsetMs else { return nil }
                return ImportedPodcastAnchorEvidence(
                    id: evidenceID,
                    localPath: localURL.path,
                    anchorOffsetMs: anchorOffsetMs,
                    provenance: descriptor.provenance
                )
            }
            importedInterjections.append(ImportedCommentaryInterjection(
                id: localID,
                layerId: layerID,
                packageScopedId: record.packageScopedId,
                createdAt: record.createdAt,
                anchorEvidence: record.anchor,
                approvedTranscript: representation.approvedTranscript,
                audioPath: asset.flatMap { contents.extractedAssetURLs[$0.id]?.path },
                audioDurationMs: asset?.durationMs,
                podcastAnchorEvidence: podcastEvidence,
                resolution: itemResolution.anchorsByPackageScopedId[record.packageScopedId]
                    ?? ImportedAnchorResolution(evidenceClass: .unresolved),
                replyLinks: replyLinks[record.packageScopedId],
                shareProvenance: MarginShareProvenance.token(representationID: representation.id)
            ))
        }
        let layer = ImportedCommentaryLayer(
            id: layerID,
            itemId: itemId,
            packageDigest: digest,
            packageId: manifest.packageId,
            itemIdentity: manifest.item,
            displayLabel: manifest.senderDisplayLabel,
            suggestedRevealMode: manifest.suggestedRevealMode,
            importedAt: importedAt,
            sourceResolutionStatus: itemResolution.status,
            isEnabled: true,
            revealMode: manifest.suggestedRevealMode ?? .companion,
            listeningMapProposals: contents.listeningMapProposals,
            editionFingerprintSpines: contents.editionFingerprintSpines,
            transcriptPhraseSketches: contents.transcriptPhraseSketches,
            // A packet may name one signature from two landmarks; uniqueKeysWithValues would trap (#536).
            episodeMapEvidencePaths: Dictionary(
                contents.editionFingerprintSpines
                    .flatMap(\.landmarks)
                    .compactMap { landmark in
                        contents.extractedAssetURLs[landmark.signatureAssetId].map {
                            (landmark.signatureAssetId, $0.path)
                        }
                    },
                uniquingKeysWith: { first, _ in first }
            )
        )
        // A sender who shares again sends their earlier Margins too; the listener keeps one copy of each (#858).
        return try ImportedMarginResends.importLayer(layer, interjections: importedInterjections, repository: repository)
    }

    public static func repairAssociation(
        existing: ImportedCommentaryLayer,
        contents: VerifiedSpokenMarginsPackage,
        itemId: String?,
        localItem: SharedItemIdentity?,
        itemText: String?,
        repository: SessionRepository
    ) throws {
        guard let itemId,
              let localItem,
              let commentary = contents.commentaryLayers.first else {
            throw SessionKitError.persistenceFailed("shared_package_repair_item_is_unavailable")
        }
        let resolution = ImportedItemResolver.resolve(
            item: contents.manifest.item,
            interjections: commentary.interjections,
            against: localItem,
            itemText: itemText
        )
        guard resolution.status != .wrongSource else {
            throw SessionKitError.persistenceFailed("shared_package_repair_source_did_not_match")
        }
        var layer = existing
        layer.itemId = itemId
        layer.sourceResolutionStatus = resolution.status
        try repository.saveImportedCommentaryLayer(layer)
        for var interjection in try repository.loadImportedCommentaryInterjections(layerId: layer.id) {
            interjection.resolution = resolution.anchorsByPackageScopedId[interjection.packageScopedId]
                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
            try repository.saveImportedCommentaryInterjection(interjection)
        }
    }

    public static func defaultLocalID(kind: String, packageScopedID: String) -> String {
        "imported-\(kind)-\(UUID().uuidString.lowercased())"
    }
}

public enum SpokenMarginsPackageExportRecord {
    /// Call after a packet is written: remembers each exported Margin's packet identity on the
    /// Margin, so replies to it that come back in someone else's packet link to it (#472).
    public static func recordExport(
        manifest: SpokenMarginsPackageManifest,
        selections: [ReviewedInterjectionSelection],
        repository: ListeningSessionRepository
    ) throws {
        guard let digest = manifest.contentDigest else {
            throw InterjectionPackagePreparationError.missingVerifiedDigest
        }
        // One transaction for the whole export, so a Margin read here is not saved over a change another thread
        // made to it in between (the anchor-evidence edits run off the main thread, #2509).
        let record = {
            for selection in selections {
                let revision = selection.revision
                guard let margin = try repository.loadInterjections(sessionId: revision.sessionId)
                    .first(where: { $0.id == revision.interjectionId }) else { continue }
                let identity = MarginPacketIdentity(packageDigest: digest, packageScopedId: selection.packageScopedId)
                try repository.saveInterjection(margin.recordingShare(as: identity))
            }
        }
        if let store = repository as? any SessionRepositoryTransaction {
            try store.withSessionTransaction(record)
        } else {
            try record()
        }
    }
}

@available(*, deprecated, renamed: "SpokenMarginsPackageBuilder")
public typealias InterjectionPackageBuilder = SpokenMarginsPackageBuilder

@available(*, deprecated, renamed: "SpokenMarginsPackageImporter")
public typealias InterjectionPackageImporter = SpokenMarginsPackageImporter
