import Foundation

public struct AlignedTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double?
    public var recognitionChunkId: String?
    public var chunkOffsetMs: Int?

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
    public var schemaVersion: String
    public var text: String
    public var localeIdentifier: String?
    public var segments: [AlignedTranscriptSegment]

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
    public var id: String
    public var kind: InterjectionCleanupDecisionKind
    public var startMs: Int
    public var endMs: Int
    public var originalText: String?
    public var accepted: Bool

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

public struct InterjectionShareRevision: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var interjectionId: String
    public var itemId: String
    public var sessionId: String
    public var createdAt: Date
    public var cleanupPolicyVersion: String
    public var approvedTranscript: String
    public var cleanedAudioPath: String?
    public var cleanedAudioDurationMs: Int?
    public var decisions: [InterjectionCleanupDecision]
    public var anchorBefore: String
    public var anchorAfter: String
    public var status: String

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
        status: String = "draft"
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
    public var sourceType: SharedSourceType
    public var canonicalURL: String
    public var originalURL: String?
    public var title: String
    public var author: String?
    public var publisher: String?
    public var showTitle: String?
    public var episodeGUID: String?
    public var enclosureURL: String?
    public var publishedAt: String?
    public var durationMs: Int?
    public var normalizedContentSHA256: String?
    public var exactEditionSHA256: String?

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
    public var anchorType: AnchorType
    public var startChar: Int?
    public var endChar: Int?
    public var exactText: String?
    public var prefix: String?
    public var suffix: String?
    public var mediaTimeMs: Int?
    public var roughPercent: Int?
    public var transcriptSegmentId: String?
    public var chapterTitle: String?

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
}

public enum ImportedCommentaryRevealMode: String, Codable, Equatable, Sendable, CaseIterable {
    case fresh
    case companion
    case guided
}

public enum ImportedCommentaryIntegrityStatus: String, Codable, Equatable, Sendable {
    case integrityCheckedUnsigned = "integrity_checked_unsigned"
    case invalidDigest = "invalid_digest"
}

public enum ImportedSourceResolutionStatus: String, Codable, Equatable, Sendable {
    case pending
    case resolved
    case contextOnly = "context_only"
    case ambiguous
    case unavailable
}

public enum ImportedCommentaryLineageStatus: String, Codable, Equatable, Sendable {
    case root
    case resolved
    case missingParent = "missing_parent"
    case fork
}

public enum AnchorResolutionEvidenceClass: String, Codable, Equatable, Sendable {
    case exactEdition = "exact_edition"
    case transcriptVerified = "transcript_verified"
    case articleTextVerified = "article_text_verified"
    case mapInterpolated = "map_interpolated"
    case acousticallyVerified = "acoustically_verified"
    case ambiguous
    case absentFromRecipientEdition = "absent_from_recipient_edition"
    case unresolved
}

public struct ImportedAnchorResolution: Codable, Equatable, Sendable {
    public var evidenceClass: AnchorResolutionEvidenceClass
    public var localStartChar: Int?
    public var localEndChar: Int?
    public var localMediaTimeMs: Int?
    public var confidence: Double?
    public var isAmbiguous: Bool
    public var algorithmVersion: String

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

public struct ImportedCommentaryLayer: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var itemId: String?
    public var packageDigest: String
    public var conversationId: String
    public var parentPackageDigests: [String]
    public var sourceIdentity: SharedSourceIdentity
    public var displayLabel: String?
    public var importedAt: Date
    public var integrityStatus: ImportedCommentaryIntegrityStatus
    public var sourceResolutionStatus: ImportedSourceResolutionStatus
    public var isEnabled: Bool
    public var isMuted: Bool
    public var revealMode: ImportedCommentaryRevealMode
    public var lineageStatus: ImportedCommentaryLineageStatus?
    public var deletedAt: Date?

    public init(
        id: String,
        itemId: String? = nil,
        packageDigest: String,
        conversationId: String,
        parentPackageDigests: [String] = [],
        sourceIdentity: SharedSourceIdentity,
        displayLabel: String? = nil,
        importedAt: Date,
        integrityStatus: ImportedCommentaryIntegrityStatus,
        sourceResolutionStatus: ImportedSourceResolutionStatus = .pending,
        isEnabled: Bool = true,
        isMuted: Bool = false,
        revealMode: ImportedCommentaryRevealMode = .companion,
        lineageStatus: ImportedCommentaryLineageStatus? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.packageDigest = packageDigest
        self.conversationId = conversationId
        self.parentPackageDigests = parentPackageDigests
        self.sourceIdentity = sourceIdentity
        self.displayLabel = displayLabel
        self.importedAt = importedAt
        self.integrityStatus = integrityStatus
        self.sourceResolutionStatus = sourceResolutionStatus
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.revealMode = revealMode
        self.lineageStatus = lineageStatus ?? (parentPackageDigests.isEmpty ? .root : .missingParent)
        self.deletedAt = deletedAt
    }
}

public struct ImportedCommentaryInterjection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var layerId: String
    public var packageScopedId: String
    public var createdAt: Date
    public var anchorEvidence: PortableAnchorEvidence
    public var approvedTranscript: String
    public var audioPath: String?
    public var audioDurationMs: Int?
    public var resolution: ImportedAnchorResolution
    public var replyToPackageScopedInterjectionId: String?

    public init(
        id: String,
        layerId: String,
        packageScopedId: String,
        createdAt: Date,
        anchorEvidence: PortableAnchorEvidence,
        approvedTranscript: String,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        resolution: ImportedAnchorResolution,
        replyToPackageScopedInterjectionId: String? = nil
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
        self.replyToPackageScopedInterjectionId = replyToPackageScopedInterjectionId
    }
}

public struct SharedInterjectionRepresentation: Codable, Equatable, Sendable {
    public var kind: String
    public var approvedTranscript: String
    public var audioPath: String?
    public var audioMimeType: String?
    public var audioDurationMs: Int?
    public var provenance: String

    public init(
        kind: String = "cleaned_audio_and_text",
        approvedTranscript: String,
        audioPath: String? = nil,
        audioMimeType: String? = nil,
        audioDurationMs: Int? = nil,
        provenance: String = "deterministic_cleanup_v1_sender_approved"
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
    public var packageScopedId: String
    public var createdAt: Date
    public var anchor: PortableAnchorEvidence
    public var representation: SharedInterjectionRepresentation
    public var replyToPackageScopedInterjectionId: String?

    public init(
        packageScopedId: String,
        createdAt: Date,
        anchor: PortableAnchorEvidence,
        representation: SharedInterjectionRepresentation,
        replyToPackageScopedInterjectionId: String? = nil
    ) {
        self.packageScopedId = packageScopedId
        self.createdAt = createdAt
        self.anchor = anchor
        self.representation = representation
        self.replyToPackageScopedInterjectionId = replyToPackageScopedInterjectionId
    }
}

public struct InterjectionPackageRedactions: Codable, Equatable, Sendable {
    public var rawAudioOmitted: Bool
    public var rawTranscriptOmitted: Bool
    public var fullSourceTextOmitted: Bool
    public var sourceAudioOmitted: Bool
    public var diagnosticsOmitted: Bool
    public var filesystemPathsOmitted: Bool
    public var unrelatedTurnsOmitted: Bool

    public init(
        rawAudioOmitted: Bool = true,
        rawTranscriptOmitted: Bool = true,
        fullSourceTextOmitted: Bool = true,
        sourceAudioOmitted: Bool = true,
        diagnosticsOmitted: Bool = true,
        filesystemPathsOmitted: Bool = true,
        unrelatedTurnsOmitted: Bool = true
    ) {
        self.rawAudioOmitted = rawAudioOmitted
        self.rawTranscriptOmitted = rawTranscriptOmitted
        self.fullSourceTextOmitted = fullSourceTextOmitted
        self.sourceAudioOmitted = sourceAudioOmitted
        self.diagnosticsOmitted = diagnosticsOmitted
        self.filesystemPathsOmitted = filesystemPathsOmitted
        self.unrelatedTurnsOmitted = unrelatedTurnsOmitted
    }
}

public struct InterjectionPackageManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var packageId: String
    public var createdAt: Date
    public var conversationId: String
    public var parentPackageDigests: [String]
    public var contentDigest: String?
    public var source: SharedSourceIdentity
    public var interjections: [SharedInterjectionPackageRecord]
    public var senderDisplayLabel: String?
    public var suggestedRevealMode: ImportedCommentaryRevealMode
    public var redactions: InterjectionPackageRedactions

    public init(
        schemaVersion: String = "spoken-margins.interjection-package.v1",
        packageId: String,
        createdAt: Date,
        conversationId: String,
        parentPackageDigests: [String] = [],
        contentDigest: String? = nil,
        source: SharedSourceIdentity,
        interjections: [SharedInterjectionPackageRecord],
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode = .companion,
        redactions: InterjectionPackageRedactions = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.packageId = packageId
        self.createdAt = createdAt
        self.conversationId = conversationId
        self.parentPackageDigests = parentPackageDigests
        self.contentDigest = contentDigest
        self.source = source
        self.interjections = interjections
        self.senderDisplayLabel = senderDisplayLabel
        self.suggestedRevealMode = suggestedRevealMode
        self.redactions = redactions
    }
}
