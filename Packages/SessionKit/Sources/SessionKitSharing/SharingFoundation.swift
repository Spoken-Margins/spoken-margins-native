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

    public init(
        packageScopedId: String,
        revision: InterjectionShareRevision,
        anchor: PortableAnchorEvidence,
        representation: ReviewedRepresentationSelection
    ) {
        self.packageScopedId = packageScopedId
        self.revision = revision
        self.anchor = anchor
        self.representation = representation
    }
}

public struct ReviewedMachineEvidenceAsset: Sendable {
    public let id: String
    public let path: String
    public let sourceURL: URL
    public let durationMs: Int

    public init(id: String, path: String, sourceURL: URL, durationMs: Int) {
        self.id = id
        self.path = path
        self.sourceURL = sourceURL
        self.durationMs = durationMs
    }
}

public enum SpokenMarginsPackageBuilder {
    public static func prepare(
        packageId: String,
        createdAt: Date,
        source: SharedSourceIdentity,
        selections: [ReviewedInterjectionSelection],
        mapProposals: [PortableListeningMapProposalArtifact] = [],
        machineEvidence: [ReviewedMachineEvidenceAsset] = [],
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil
    ) throws -> PreparedSpokenMarginsPackage {
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

            let representation: SharedInterjectionRepresentation
            switch selection.representation {
            case .textOnly:
                representation = SharedInterjectionRepresentation(
                    id: String(format: "representation-%04d-text", index + 1),
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
                    id: String(format: "representation-%04d-original", index + 1),
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
                    id: String(format: "representation-%04d-cleaned", index + 1),
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
                    suffix: revision.anchorAfter
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
                provenance: "exact_playback_edition"
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

        return PreparedSpokenMarginsPackage(
            manifest: SpokenMarginsPackageManifest(
                packageId: packageId,
                createdAt: createdAt,
                source: source,
                senderDisplayLabel: senderDisplayLabel,
                suggestedRevealMode: suggestedRevealMode,
                requiredCapabilities: [SharedCommentaryLayerArtifact.schemaVersion],
                artifacts: artifacts,
                assets: assets
            ),
            artifactData: artifactData,
            assetFiles: assetFiles
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
        localSource: SharedSourceIdentity? = nil,
        sourceText: String? = nil,
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
        let sourceResolution = localSource.map {
            ImportedSourceResolver.resolve(
                source: manifest.source,
                interjections: commentary.interjections,
                against: $0,
                sourceText: sourceText
            )
        } ?? ImportedSourceResolver.pending(interjections: commentary.interjections)
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
            importedInterjections.append(ImportedCommentaryInterjection(
                id: localID,
                layerId: layerID,
                packageScopedId: record.packageScopedId,
                createdAt: record.createdAt,
                anchorEvidence: record.anchor,
                approvedTranscript: representation.approvedTranscript,
                audioPath: asset.flatMap { contents.extractedAssetURLs[$0.id]?.path },
                audioDurationMs: asset?.durationMs,
                resolution: sourceResolution.anchorsByPackageScopedId[record.packageScopedId]
                    ?? ImportedAnchorResolution(evidenceClass: .unresolved)
            ))
        }
        let layer = ImportedCommentaryLayer(
            id: layerID,
            itemId: itemId,
            packageDigest: digest,
            packageId: manifest.packageId,
            sourceIdentity: manifest.source,
            displayLabel: manifest.senderDisplayLabel,
            suggestedRevealMode: manifest.suggestedRevealMode,
            importedAt: importedAt,
            sourceResolutionStatus: sourceResolution.status,
            isEnabled: false,
            revealMode: nil
        )
        return try repository.importCommentaryLayer(layer, interjections: importedInterjections)
    }

    public static func defaultLocalID(kind: String, packageScopedID: String) -> String {
        "imported-\(kind)-\(UUID().uuidString.lowercased())"
    }
}

@available(*, deprecated, renamed: "SpokenMarginsPackageBuilder")
public typealias InterjectionPackageBuilder = SpokenMarginsPackageBuilder

@available(*, deprecated, renamed: "SpokenMarginsPackageImporter")
public typealias InterjectionPackageImporter = SpokenMarginsPackageImporter
