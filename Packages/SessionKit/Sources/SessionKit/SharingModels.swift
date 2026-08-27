import Foundation

public struct AlignedTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Double?
    public let recognitionChunkId: String?
    public let chunkOffsetMs: Int?

    public init(
        id: String,
        text: String,
        startMs: Int,
        endMs: Int,
        confidence: Double? = nil,
        recognitionChunkId: String? = nil,
        chunkOffsetMs: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.recognitionChunkId = recognitionChunkId
        self.chunkOffsetMs = chunkOffsetMs
    }
}

public struct AlignedInterjectionTranscript: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let text: String
    public let localeIdentifier: String?
    public let segments: [AlignedTranscriptSegment]

    public init(
        schemaVersion: String = "aligned-interjection-transcript.v1",
        text: String,
        localeIdentifier: String? = nil,
        segments: [AlignedTranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.segments = segments
    }
}

public enum InterjectionCleanupDecisionKind: String, Codable, Equatable, Sendable {
    case filler
    case isolatedPhrase = "isolated_phrase"
    case longPause = "long_pause"
}

public struct InterjectionCleanupDecision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: InterjectionCleanupDecisionKind
    public let startMs: Int
    public let endMs: Int
    public let originalText: String?
    public let accepted: Bool

    public init(
        id: String,
        kind: InterjectionCleanupDecisionKind,
        startMs: Int,
        endMs: Int,
        originalText: String? = nil,
        accepted: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.startMs = startMs
        self.endMs = endMs
        self.originalText = originalText
        self.accepted = accepted
    }
}

public enum InterjectionShareRevisionStatus: String, Codable, Equatable, Sendable {
    case draft
    case senderReviewPending = "sender_review_pending"
    case senderApproved = "sender_approved"
}

/// A value snapshot derived from a private capture. Creating or exporting a revision
/// never updates the private `Interjection` record or any of its representations.
public struct InterjectionShareRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let interjectionId: String
    public let itemId: String
    public let sessionId: String
    public let createdAt: Date
    public let cleanupPolicyVersion: String
    public let approvedTranscript: String
    public let cleanedAudioPath: String?
    public let cleanedAudioDurationMs: Int?
    public let decisions: [InterjectionCleanupDecision]
    public let anchorBefore: String
    public let anchorAfter: String
    public let status: InterjectionShareRevisionStatus

    public init(
        id: String,
        interjectionId: String,
        itemId: String,
        sessionId: String,
        createdAt: Date,
        cleanupPolicyVersion: String = "cleanup.v1",
        approvedTranscript: String,
        cleanedAudioPath: String? = nil,
        cleanedAudioDurationMs: Int? = nil,
        decisions: [InterjectionCleanupDecision] = [],
        anchorBefore: String,
        anchorAfter: String,
        status: InterjectionShareRevisionStatus = .draft
    ) {
        self.id = id
        self.interjectionId = interjectionId
        self.itemId = itemId
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.cleanupPolicyVersion = cleanupPolicyVersion
        self.approvedTranscript = approvedTranscript
        self.cleanedAudioPath = cleanedAudioPath
        self.cleanedAudioDurationMs = cleanedAudioDurationMs
        self.decisions = decisions
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.status = status
    }
}

public enum SharedSourceType: String, Codable, Equatable, Sendable {
    case article
    case podcast
    case other
}

public struct SharedSourceIdentity: Codable, Equatable, Sendable {
    public let sourceType: SharedSourceType
    public let canonicalURL: String
    public let originalURL: String?
    public let title: String
    public let author: String?
    public let publisher: String?
    public let showTitle: String?
    public let episodeGUID: String?
    public let enclosureURL: String?
    public let publishedAt: String?
    public let durationMs: Int?
    public let normalizedContentSHA256: String?
    public let exactEditionSHA256: String?

    public init(
        sourceType: SharedSourceType,
        canonicalURL: String,
        originalURL: String? = nil,
        title: String,
        author: String? = nil,
        publisher: String? = nil,
        showTitle: String? = nil,
        episodeGUID: String? = nil,
        enclosureURL: String? = nil,
        publishedAt: String? = nil,
        durationMs: Int? = nil,
        normalizedContentSHA256: String? = nil,
        exactEditionSHA256: String? = nil
    ) {
        self.sourceType = sourceType
        self.canonicalURL = canonicalURL
        self.originalURL = originalURL
        self.title = title
        self.author = author
        self.publisher = publisher
        self.showTitle = showTitle
        self.episodeGUID = episodeGUID
        self.enclosureURL = enclosureURL
        self.publishedAt = publishedAt
        self.durationMs = durationMs
        self.normalizedContentSHA256 = normalizedContentSHA256
        self.exactEditionSHA256 = exactEditionSHA256
    }
}

public struct PortableAnchorEvidence: Codable, Equatable, Sendable {
    public let anchorType: AnchorType
    public let startChar: Int?
    public let endChar: Int?
    public let exactText: String?
    public let prefix: String?
    public let suffix: String?
    public let mediaTimeMs: Int?
    public let roughPercent: Int?
    public let transcriptSegmentId: String?
    public let chapterTitle: String?

    public init(
        anchorType: AnchorType,
        startChar: Int? = nil,
        endChar: Int? = nil,
        exactText: String? = nil,
        prefix: String? = nil,
        suffix: String? = nil,
        mediaTimeMs: Int? = nil,
        roughPercent: Int? = nil,
        transcriptSegmentId: String? = nil,
        chapterTitle: String? = nil
    ) {
        self.anchorType = anchorType
        self.startChar = startChar
        self.endChar = endChar
        self.exactText = exactText
        self.prefix = prefix
        self.suffix = suffix
        self.mediaTimeMs = mediaTimeMs
        self.roughPercent = roughPercent
        self.transcriptSegmentId = transcriptSegmentId
        self.chapterTitle = chapterTitle
    }

    public func bounded(
        prefix replacementPrefix: String? = nil,
        suffix replacementSuffix: String? = nil
    ) -> PortableAnchorEvidence {
        let context = BoundedAnchorContext.select(
            before: replacementPrefix ?? prefix ?? "",
            after: replacementSuffix ?? suffix ?? ""
        )
        return PortableAnchorEvidence(
            anchorType: anchorType,
            startChar: startChar,
            endChar: endChar,
            exactText: exactText.map { String($0.prefix(BoundedAnchorContext.maximumExactTextCharacters)) },
            prefix: context.before.isEmpty ? nil : context.before,
            suffix: context.after.isEmpty ? nil : context.after,
            mediaTimeMs: mediaTimeMs,
            roughPercent: roughPercent.map { min(100, max(0, $0)) },
            transcriptSegmentId: transcriptSegmentId,
            chapterTitle: chapterTitle
        )
    }
}

public enum ImportedCommentaryRevealMode: String, Codable, Equatable, Sendable, CaseIterable {
    case fresh
    case companion
    case guided
}

public enum ImportedCommentaryIntegrityStatus: String, Codable, Equatable, Sendable {
    case integrityCheckedUnsigned = "integrity_checked_unsigned"
}

public enum ImportedSourceResolutionStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
    case contextOnly = "context_only"
    case ambiguous
    case wrongSource = "wrong_source"
    case unavailable
}

public enum AnchorResolutionEvidenceClass: String, Codable, Equatable, Sendable {
    case exactEdition = "exact_edition"
    case articleTextVerified = "article_text_verified"
    case transcriptVerified = "transcript_verified"
    case ambiguous
    case absentFromRecipientEdition = "absent_from_recipient_edition"
    case unresolved
}

public struct ImportedAnchorResolution: Codable, Equatable, Sendable {
    public let evidenceClass: AnchorResolutionEvidenceClass
    public let localStartChar: Int?
    public let localEndChar: Int?
    public let localMediaTimeMs: Int?
    public let confidence: Double?
    public let isAmbiguous: Bool
    public let algorithmVersion: String

    public init(
        evidenceClass: AnchorResolutionEvidenceClass,
        localStartChar: Int? = nil,
        localEndChar: Int? = nil,
        localMediaTimeMs: Int? = nil,
        confidence: Double? = nil,
        isAmbiguous: Bool = false,
        algorithmVersion: String = "anchor-resolution.v1"
    ) {
        self.evidenceClass = evidenceClass
        self.localStartChar = localStartChar
        self.localEndChar = localEndChar
        self.localMediaTimeMs = localMediaTimeMs
        self.confidence = confidence
        self.isAmbiguous = isAmbiguous
        self.algorithmVersion = algorithmVersion
    }
}

/// Source resolution is recorded per imported note. The aggregate layer status is
/// derived from these results so a layer cannot claim to be resolved while its
/// individual anchors remain unresolved.
public struct ImportedPackageSourceResolution: Codable, Equatable, Sendable {
    public let status: ImportedSourceResolutionStatus
    public let anchorsByPackageScopedId: [String: ImportedAnchorResolution]

    public init(
        status: ImportedSourceResolutionStatus,
        anchorsByPackageScopedId: [String: ImportedAnchorResolution]
    ) {
        self.status = status
        self.anchorsByPackageScopedId = anchorsByPackageScopedId
    }
}

/// Imported commentary is persisted independently from private, locally captured
/// interjections. `id` is always recipient-local; `packageDigest` is the idempotency key.
public struct ImportedCommentaryLayer: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var itemId: String?
    public let packageDigest: String
    public let packageId: String
    public let sourceIdentity: SharedSourceIdentity
    public let displayLabel: String?
    public let suggestedRevealMode: ImportedCommentaryRevealMode?
    public let importedAt: Date
    public let integrityStatus: ImportedCommentaryIntegrityStatus
    public var sourceResolutionStatus: ImportedSourceResolutionStatus
    public var isEnabled: Bool
    public var isMuted: Bool
    public var revealMode: ImportedCommentaryRevealMode?
    public var deletedAt: Date?

    public init(
        id: String,
        itemId: String? = nil,
        packageDigest: String,
        packageId: String,
        sourceIdentity: SharedSourceIdentity,
        displayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil,
        importedAt: Date,
        integrityStatus: ImportedCommentaryIntegrityStatus = .integrityCheckedUnsigned,
        sourceResolutionStatus: ImportedSourceResolutionStatus = .pending,
        isEnabled: Bool = false,
        isMuted: Bool = false,
        revealMode: ImportedCommentaryRevealMode? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.packageDigest = packageDigest
        self.packageId = packageId
        self.sourceIdentity = sourceIdentity
        self.displayLabel = displayLabel
        self.suggestedRevealMode = suggestedRevealMode
        self.importedAt = importedAt
        self.integrityStatus = integrityStatus
        self.sourceResolutionStatus = sourceResolutionStatus
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.revealMode = revealMode
        self.deletedAt = deletedAt
    }
}

public struct ImportedCommentaryInterjection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let layerId: String
    public let packageScopedId: String
    public let createdAt: Date
    public let anchorEvidence: PortableAnchorEvidence
    public let approvedTranscript: String
    public let audioPath: String?
    public let audioDurationMs: Int?
    public var resolution: ImportedAnchorResolution

    public init(
        id: String,
        layerId: String,
        packageScopedId: String,
        createdAt: Date,
        anchorEvidence: PortableAnchorEvidence,
        approvedTranscript: String,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved)
    ) {
        self.id = id
        self.layerId = layerId
        self.packageScopedId = packageScopedId
        self.createdAt = createdAt
        self.anchorEvidence = anchorEvidence
        self.approvedTranscript = approvedTranscript
        self.audioPath = audioPath
        self.audioDurationMs = audioDurationMs
        self.resolution = resolution
    }
}

public enum ImportedCommentaryImportDisposition: Equatable, Sendable {
    case imported(layerId: String, interjectionIds: [String])
    case duplicate(existingLayerId: String)
}

public enum SharedInterjectionRepresentationKind: String, Codable, Equatable, Sendable {
    case cleanedAudioAndText = "cleaned_audio_and_text"
    case textOnly = "text_only"
}

public enum SharedInterjectionProvenance: String, Codable, Equatable, Sendable {
    case deterministicCleanupV1SenderApproved = "deterministic_cleanup_v1_sender_approved"
    case senderApprovedTextOnly = "sender_approved_text_only"
}

public struct SharedInterjectionRepresentation: Codable, Equatable, Sendable {
    public let kind: SharedInterjectionRepresentationKind
    public let approvedTranscript: String
    public let audioPath: String?
    public let audioMimeType: String?
    public let audioDurationMs: Int?
    public let provenance: SharedInterjectionProvenance

    public init(
        kind: SharedInterjectionRepresentationKind,
        approvedTranscript: String,
        audioPath: String? = nil,
        audioMimeType: String? = nil,
        audioDurationMs: Int? = nil,
        provenance: SharedInterjectionProvenance
    ) {
        self.kind = kind
        self.approvedTranscript = approvedTranscript
        self.audioPath = audioPath
        self.audioMimeType = audioMimeType
        self.audioDurationMs = audioDurationMs
        self.provenance = provenance
    }
}

public struct SharedInterjectionPackageRecord: Codable, Equatable, Sendable {
    public let packageScopedId: String
    public let createdAt: Date
    public let anchor: PortableAnchorEvidence
    public let representation: SharedInterjectionRepresentation

    public init(
        packageScopedId: String,
        createdAt: Date,
        anchor: PortableAnchorEvidence,
        representation: SharedInterjectionRepresentation
    ) {
        self.packageScopedId = packageScopedId
        self.createdAt = createdAt
        self.anchor = anchor
        self.representation = representation
    }
}

public struct InterjectionPackageRedactions: Codable, Equatable, Sendable {
    public let rawAudioOmitted: Bool
    public let rawTranscriptOmitted: Bool
    public let fullSourceTextOmitted: Bool
    public let sourceAudioOmitted: Bool
    public let diagnosticsOmitted: Bool
    public let filesystemPathsOmitted: Bool
    public let unrelatedTurnsOmitted: Bool
    public let privateRepresentationsOmitted: Bool

    public init(
        rawAudioOmitted: Bool = true,
        rawTranscriptOmitted: Bool = true,
        fullSourceTextOmitted: Bool = true,
        sourceAudioOmitted: Bool = true,
        diagnosticsOmitted: Bool = true,
        filesystemPathsOmitted: Bool = true,
        unrelatedTurnsOmitted: Bool = true,
        privateRepresentationsOmitted: Bool = true
    ) {
        self.rawAudioOmitted = rawAudioOmitted
        self.rawTranscriptOmitted = rawTranscriptOmitted
        self.fullSourceTextOmitted = fullSourceTextOmitted
        self.sourceAudioOmitted = sourceAudioOmitted
        self.diagnosticsOmitted = diagnosticsOmitted
        self.filesystemPathsOmitted = filesystemPathsOmitted
        self.unrelatedTurnsOmitted = unrelatedTurnsOmitted
        self.privateRepresentationsOmitted = privateRepresentationsOmitted
    }

    public var provesDefaultMinimization: Bool {
        rawAudioOmitted
            && rawTranscriptOmitted
            && fullSourceTextOmitted
            && sourceAudioOmitted
            && diagnosticsOmitted
            && filesystemPathsOmitted
            && unrelatedTurnsOmitted
            && privateRepresentationsOmitted
    }
}

public struct InterjectionPackageManifest: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let packageId: String
    public let createdAt: Date
    public var contentDigest: String?
    public let source: SharedSourceIdentity
    public let interjections: [SharedInterjectionPackageRecord]
    public let senderDisplayLabel: String?
    public let suggestedRevealMode: ImportedCommentaryRevealMode?
    public let redactions: InterjectionPackageRedactions

    public init(
        schemaVersion: String = "spoken-margins.interjection-package.v1",
        packageId: String,
        createdAt: Date,
        contentDigest: String? = nil,
        source: SharedSourceIdentity,
        interjections: [SharedInterjectionPackageRecord],
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil,
        redactions: InterjectionPackageRedactions = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.packageId = packageId
        self.createdAt = createdAt
        self.contentDigest = contentDigest
        self.source = source
        self.interjections = interjections
        self.senderDisplayLabel = senderDisplayLabel
        self.suggestedRevealMode = suggestedRevealMode
        self.redactions = redactions
    }
}
