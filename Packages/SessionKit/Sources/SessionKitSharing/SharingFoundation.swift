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

public struct PreparedInterjectionPackage: Sendable {
    public let manifest: InterjectionPackageManifest
    public let audioFiles: [String: URL]

    public init(manifest: InterjectionPackageManifest, audioFiles: [String: URL]) {
        self.manifest = manifest
        self.audioFiles = audioFiles
    }
}

public enum InterjectionPackageBuilder {
    public static func prepare(
        packageId: String,
        createdAt: Date,
        source: SharedSourceIdentity,
        selections: [ReviewedInterjectionSelection],
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil
    ) throws -> PreparedInterjectionPackage {
        let scopedIds = selections.map(\.packageScopedId)
        if let duplicate = Dictionary(grouping: scopedIds, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw InterjectionPackagePreparationError.duplicatePackageScopedId(duplicate)
        }

        var records: [SharedInterjectionPackageRecord] = []
        var audioFiles: [String: URL] = [:]
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
                    kind: .textOnly,
                    approvedTranscript: approvedTranscript,
                    provenance: .senderApprovedTextOnly
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
                let archivePath = String(format: "audio/interjection-%04d.m4a", index + 1)
                audioFiles[archivePath] = sourceURL
                representation = SharedInterjectionRepresentation(
                    kind: .cleanedAudioAndText,
                    approvedTranscript: approvedTranscript,
                    audioPath: archivePath,
                    audioMimeType: "audio/mp4",
                    audioDurationMs: duration,
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
                representation: representation
            ))
        }

        return PreparedInterjectionPackage(
            manifest: InterjectionPackageManifest(
                packageId: packageId,
                createdAt: createdAt,
                source: source,
                interjections: records,
                senderDisplayLabel: senderDisplayLabel,
                suggestedRevealMode: suggestedRevealMode
            ),
            audioFiles: audioFiles
        )
    }
}

public enum InterjectionPackageImporter {
    public typealias LocalIDProvider = (_ kind: String, _ packageScopedID: String) -> String

    public static func importPackage(
        _ contents: VerifiedInterjectionPackage,
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
        let sourceResolution = localSource.map {
            ImportedSourceResolver.resolve(package: manifest, against: $0, sourceText: sourceText)
        } ?? ImportedSourceResolver.pending(package: manifest)
        let layerID = makeLocalID("layer", manifest.packageId)
        let packageIDs = Set([manifest.packageId] + manifest.interjections.map(\.packageScopedId))
        guard !layerID.isEmpty, !packageIDs.contains(layerID) else {
            throw InterjectionPackagePreparationError.invalidLocalIdentity(layerID)
        }
        var generatedIDs: Set<String> = [layerID]
        var importedInterjections: [ImportedCommentaryInterjection] = []
        for record in manifest.interjections {
            let localID = makeLocalID("interjection", record.packageScopedId)
            guard !localID.isEmpty,
                  !packageIDs.contains(localID),
                  generatedIDs.insert(localID).inserted else {
                throw InterjectionPackagePreparationError.invalidLocalIdentity(localID)
            }
            importedInterjections.append(ImportedCommentaryInterjection(
                id: localID,
                layerId: layerID,
                packageScopedId: record.packageScopedId,
                createdAt: record.createdAt,
                anchorEvidence: record.anchor,
                approvedTranscript: record.representation.approvedTranscript,
                audioPath: record.representation.audioPath.flatMap { contents.extractedAudioURLs[$0]?.path },
                audioDurationMs: record.representation.audioDurationMs,
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
