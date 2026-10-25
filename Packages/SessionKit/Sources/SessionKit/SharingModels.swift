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
    case manualWord = "manual_word"
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

public enum SharedItemType: String, Codable, Equatable, Sendable {
    case text
    case podcast
    case pdf
    case epub
    case other
}

public struct SharedSourceIdentity: Codable, Equatable, Sendable {
    public enum SourceType: String, Codable, Equatable, Sendable {
        case podcastFeed = "podcast_feed"
        case textFeed = "text_feed"
        case newsletter
        case blog
        case socialFeed = "social_feed"
        case other
    }

    public let sourceType: SourceType
    public let canonicalURL: String
    public let title: String?
    public let publisher: String?

    public init(
        sourceType: SourceType,
        canonicalURL: String,
        title: String? = nil,
        publisher: String? = nil
    ) {
        self.sourceType = sourceType
        self.canonicalURL = canonicalURL
        self.title = title
        self.publisher = publisher
    }
}

public struct SharedItemIdentity: Codable, Equatable, Sendable {
    public let itemType: SharedItemType
    public let canonicalURL: String?
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
    public let languageCode: String?
    public let source: SharedSourceIdentity?

    public init(
        itemType: SharedItemType,
        canonicalURL: String? = nil,
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
        exactEditionSHA256: String? = nil,
        languageCode: String? = nil,
        source: SharedSourceIdentity? = nil
    ) {
        self.itemType = itemType
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
        self.languageCode = languageCode
        self.source = source
    }
}

public enum SharedItemTransportKind: String, Codable, Equatable, Sendable {
    case reference
    case embeddedText = "embedded_text"
    case recipientSupplied = "recipient_supplied"
}

public enum SharedItemRightsBasis: String, Codable, Equatable, Sendable {
    case appAuthored = "app_authored"
    case senderConfirmedPrivateRights = "sender_confirmed_private_rights"
}

public struct SharedItemTransport: Codable, Equatable, Sendable {
    public let kind: SharedItemTransportKind
    public let embeddedArtifactId: String?
    public let rightsBasis: SharedItemRightsBasis?

    public init(
        kind: SharedItemTransportKind,
        embeddedArtifactId: String? = nil,
        rightsBasis: SharedItemRightsBasis? = nil
    ) {
        self.kind = kind
        self.embeddedArtifactId = embeddedArtifactId
        self.rightsBasis = rightsBasis
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
    public let machineEvidenceAssetIds: [String]

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
        chapterTitle: String? = nil,
        machineEvidenceAssetIds: [String] = []
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
        self.machineEvidenceAssetIds = machineEvidenceAssetIds
    }

    public func bounded(
        prefix replacementPrefix: String? = nil,
        suffix replacementSuffix: String? = nil,
        commentLength: Int? = nil
    ) -> PortableAnchorEvidence {
        let before = replacementPrefix ?? prefix ?? ""
        let after = replacementSuffix ?? suffix ?? ""
        // A Margin's packet follows the excerpt cap rule (#2237); anything else (a Listening Map) keeps its bound.
        let context = commentLength.map { ExcerptCapRule.select(before: before, after: after, commentLength: $0) }
            ?? BoundedAnchorContext.select(before: before, after: after)
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
            chapterTitle: chapterTitle,
            machineEvidenceAssetIds: machineEvidenceAssetIds
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
    case acousticVerified = "acoustic_verified"
    case fused
    case mapInterpolated = "map_interpolated"
    case timestampFallback = "timestamp_fallback"
    case recipientConfirmed = "recipient_confirmed"
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

/// Item resolution is recorded per imported note. The aggregate layer status is
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
    public let itemIdentity: SharedItemIdentity
    public let displayLabel: String?
    public let suggestedRevealMode: ImportedCommentaryRevealMode?
    public let importedAt: Date
    public let integrityStatus: ImportedCommentaryIntegrityStatus
    /// Recipient-local audio identity for the saved anchor results. Older rows
    /// decode as unknown and must be reverified before retaining stale evidence.
    public var resolvedRecipientEditionSHA256: String?
    public var sourceResolutionStatus: ImportedSourceResolutionStatus
    public var isEnabled: Bool
    public var isMuted: Bool
    public var revealMode: ImportedCommentaryRevealMode?
    public var deletedAt: Date?
    /// Sender proposals remain inert recipient data until a future explicit
    /// review flow accepts them into a local Listening Map.
    public let listeningMapProposals: [PortableListeningMapProposalArtifact]?
    /// Private episode-map derivatives included with a user-initiated Margin
    /// share. Neither structure contains transcript text or playable source audio.
    public let editionFingerprintSpines: [EditionFingerprintSpineArtifact]?
    public let transcriptPhraseSketches: [TranscriptPhraseSketchArtifact]?
    public let episodeMapEvidencePaths: [String: String]?
    /// Why this packet's shared map couldn't be placed on the listener's copy, kept so the
    /// item can still say why after a restart (#481). Nil when a shared map is in use or
    /// the listener has their own; older builds ignore the field.
    public var sharedMapRefusalReason: String?

    public init(
        id: String,
        itemId: String? = nil,
        packageDigest: String,
        packageId: String,
        itemIdentity: SharedItemIdentity,
        displayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil,
        importedAt: Date,
        integrityStatus: ImportedCommentaryIntegrityStatus = .integrityCheckedUnsigned,
        sourceResolutionStatus: ImportedSourceResolutionStatus = .pending,
        isEnabled: Bool = false,
        isMuted: Bool = false,
        revealMode: ImportedCommentaryRevealMode? = nil,
        deletedAt: Date? = nil,
        listeningMapProposals: [PortableListeningMapProposalArtifact]? = nil,
        editionFingerprintSpines: [EditionFingerprintSpineArtifact]? = nil,
        transcriptPhraseSketches: [TranscriptPhraseSketchArtifact]? = nil,
        episodeMapEvidencePaths: [String: String]? = nil,
        resolvedRecipientEditionSHA256: String? = nil,
        sharedMapRefusalReason: String? = nil
    ) {
        self.sharedMapRefusalReason = sharedMapRefusalReason
        self.resolvedRecipientEditionSHA256 = resolvedRecipientEditionSHA256
        self.id = id
        self.itemId = itemId
        self.packageDigest = packageDigest
        self.packageId = packageId
        self.itemIdentity = itemIdentity
        self.displayLabel = displayLabel
        self.suggestedRevealMode = suggestedRevealMode
        self.importedAt = importedAt
        self.integrityStatus = integrityStatus
        self.sourceResolutionStatus = sourceResolutionStatus
        self.isEnabled = isEnabled
        self.isMuted = isMuted
        self.revealMode = revealMode
        self.deletedAt = deletedAt
        self.listeningMapProposals = listeningMapProposals
        self.editionFingerprintSpines = editionFingerprintSpines
        self.transcriptPhraseSketches = transcriptPhraseSketches
        self.episodeMapEvidencePaths = episodeMapEvidencePaths
    }

    private enum CodingKeys: String, CodingKey {
        case id, itemId, packageDigest, packageId, itemIdentity, sourceIdentity
        case displayLabel, suggestedRevealMode, importedAt, integrityStatus
        case resolvedRecipientEditionSHA256
        case sourceResolutionStatus, isEnabled, isMuted, revealMode, deletedAt
        case listeningMapProposals, editionFingerprintSpines, transcriptPhraseSketches, episodeMapEvidencePaths
        case sharedMapRefusalReason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        resolvedRecipientEditionSHA256 = try values.decodeIfPresent(String.self, forKey: .resolvedRecipientEditionSHA256)
        id = try values.decode(String.self, forKey: .id)
        itemId = try values.decodeIfPresent(String.self, forKey: .itemId)
        packageDigest = try values.decode(String.self, forKey: .packageDigest)
        packageId = try values.decode(String.self, forKey: .packageId)
        if let current = try values.decodeIfPresent(SharedItemIdentity.self, forKey: .itemIdentity) {
            itemIdentity = current
        } else {
            let legacy = try values.decode(LegacySharedItemIdentity.self, forKey: .sourceIdentity)
            itemIdentity = legacy.currentIdentity
        }
        displayLabel = try values.decodeIfPresent(String.self, forKey: .displayLabel)
        suggestedRevealMode = try values.decodeIfPresent(ImportedCommentaryRevealMode.self, forKey: .suggestedRevealMode)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        integrityStatus = try values.decodeIfPresent(ImportedCommentaryIntegrityStatus.self, forKey: .integrityStatus)
            ?? .integrityCheckedUnsigned
        sourceResolutionStatus = try values.decodeIfPresent(ImportedSourceResolutionStatus.self, forKey: .sourceResolutionStatus)
            ?? .pending
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        revealMode = try values.decodeIfPresent(ImportedCommentaryRevealMode.self, forKey: .revealMode)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        listeningMapProposals = try values.decodeIfPresent(
            [PortableListeningMapProposalArtifact].self,
            forKey: .listeningMapProposals
        )
        editionFingerprintSpines = try values.decodeIfPresent(
            [EditionFingerprintSpineArtifact].self,
            forKey: .editionFingerprintSpines
        )
        transcriptPhraseSketches = try values.decodeIfPresent(
            [TranscriptPhraseSketchArtifact].self,
            forKey: .transcriptPhraseSketches
        )
        episodeMapEvidencePaths = try values.decodeIfPresent([String: String].self, forKey: .episodeMapEvidencePaths)
        sharedMapRefusalReason = try values.decodeIfPresent(String.self, forKey: .sharedMapRefusalReason)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(resolvedRecipientEditionSHA256, forKey: .resolvedRecipientEditionSHA256)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(itemId, forKey: .itemId)
        try values.encode(packageDigest, forKey: .packageDigest)
        try values.encode(packageId, forKey: .packageId)
        try values.encode(itemIdentity, forKey: .itemIdentity)
        try values.encodeIfPresent(displayLabel, forKey: .displayLabel)
        try values.encodeIfPresent(suggestedRevealMode, forKey: .suggestedRevealMode)
        try values.encode(importedAt, forKey: .importedAt)
        try values.encode(integrityStatus, forKey: .integrityStatus)
        try values.encode(sourceResolutionStatus, forKey: .sourceResolutionStatus)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(isMuted, forKey: .isMuted)
        try values.encodeIfPresent(revealMode, forKey: .revealMode)
        try values.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try values.encodeIfPresent(listeningMapProposals, forKey: .listeningMapProposals)
        try values.encodeIfPresent(editionFingerprintSpines, forKey: .editionFingerprintSpines)
        try values.encodeIfPresent(transcriptPhraseSketches, forKey: .transcriptPhraseSketches)
        try values.encodeIfPresent(episodeMapEvidencePaths, forKey: .episodeMapEvidencePaths)
        try values.encodeIfPresent(sharedMapRefusalReason, forKey: .sharedMapRefusalReason)
    }
}

private struct LegacySharedItemIdentity: Decodable {
    let sourceType: String
    let canonicalURL: String
    let originalURL: String?
    let title: String
    let author: String?
    let publisher: String?
    let showTitle: String?
    let episodeGUID: String?
    let enclosureURL: String?
    let publishedAt: String?
    let durationMs: Int?
    let normalizedContentSHA256: String?
    let exactEditionSHA256: String?
    let languageCode: String?

    var currentIdentity: SharedItemIdentity {
        SharedItemIdentity(
            itemType: sourceType == "podcast" ? .podcast : (sourceType == "article" ? .text : .other),
            canonicalURL: canonicalURL,
            originalURL: originalURL,
            title: title,
            author: author,
            publisher: publisher,
            showTitle: showTitle,
            episodeGUID: episodeGUID,
            enclosureURL: enclosureURL,
            publishedAt: publishedAt,
            durationMs: durationMs,
            normalizedContentSHA256: normalizedContentSHA256,
            exactEditionSHA256: exactEditionSHA256,
            languageCode: languageCode
        )
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
    public let podcastAnchorEvidence: [ImportedPodcastAnchorEvidence]?
    public var resolution: ImportedAnchorResolution
    /// When this listener first heard the Margin's voice; nil while it's new to them (#469).
    /// Local only: packets never carry it, and Build 29 ignores the key when it reads the record.
    public var firstHeardAt: Date?

    /// Not heard yet, so the Timeline and the Margins list mark it as new.
    public var isNewToListener: Bool { firstHeardAt == nil }
    /// The Margins this one answers, from the packet's conversation artifact (#472). Nil for an
    /// ordinary Margin; more than one link is a fork. Build 29 ignores it.
    public let replyLinks: [MarginReplyLink]?
    /// Where else this same Margin arrived: later packets from the same sender that carried it again
    /// are not imported a second time, so replies to their copy still find this one (#858). Nil for
    /// a Margin that arrived once. Local only; Build 29 ignores the key when it reads the record.
    public var alsoSharedAs: [MarginPacketIdentity]?
    /// Stable capture provenance from the selected representation ID. Older packets have none;
    /// matching words and a display label alone cannot prove they came from the same person.
    /// Local JSON only; Build 29 ignores this optional key.
    public let shareProvenance: String?

    public init(
        id: String,
        layerId: String,
        packageScopedId: String,
        createdAt: Date,
        anchorEvidence: PortableAnchorEvidence,
        approvedTranscript: String,
        audioPath: String? = nil,
        audioDurationMs: Int? = nil,
        podcastAnchorEvidence: [ImportedPodcastAnchorEvidence]? = nil,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved),
        firstHeardAt: Date? = nil,
        replyLinks: [MarginReplyLink]? = nil,
        alsoSharedAs: [MarginPacketIdentity]? = nil,
        shareProvenance: String? = nil
    ) {
        self.id = id
        self.layerId = layerId
        self.packageScopedId = packageScopedId
        self.createdAt = createdAt
        self.anchorEvidence = anchorEvidence
        self.approvedTranscript = approvedTranscript
        self.audioPath = audioPath
        self.audioDurationMs = audioDurationMs
        self.podcastAnchorEvidence = podcastAnchorEvidence
        self.resolution = resolution
        self.firstHeardAt = firstHeardAt
        self.replyLinks = replyLinks
        self.alsoSharedAs = alsoSharedAs
        self.shareProvenance = shareProvenance
    }
}

public struct ImportedPodcastAnchorEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let localPath: String
    public let anchorOffsetMs: Int
    public let provenance: String?

    public init(
        id: String,
        localPath: String,
        anchorOffsetMs: Int,
        provenance: String? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.anchorOffsetMs = anchorOffsetMs
        self.provenance = provenance
    }
}

public enum ImportedCommentaryImportDisposition: Equatable, Sendable {
    case imported(layerId: String, interjectionIds: [String])
    case duplicate(existingLayerId: String)
}

public enum SharedInterjectionRepresentationKind: String, Codable, Equatable, Sendable {
    case originalAudioAndText = "original_audio_and_text"
    case cleanedAudioAndText = "cleaned_audio_and_text"
    case textOnly = "text_only"
    case summaryText = "summary_text"
    case summaryAudioAndText = "summary_audio_and_text"
    case ttsAudioAndText = "tts_audio_and_text"
}

public enum SharedInterjectionProvenance: String, Codable, Equatable, Sendable {
    case senderApprovedOriginal = "sender_approved_original"
    case deterministicCleanupV1SenderApproved = "deterministic_cleanup_v1_sender_approved"
    case senderApprovedTextOnly = "sender_approved_text_only"
    case senderApprovedSummary = "sender_approved_summary"
    case senderApprovedTTS = "sender_approved_tts"
}

public struct SharedInterjectionRepresentation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: SharedInterjectionRepresentationKind
    public let approvedTranscript: String
    public let assetId: String?
    public let provenance: SharedInterjectionProvenance

    public init(
        id: String,
        kind: SharedInterjectionRepresentationKind,
        approvedTranscript: String,
        assetId: String? = nil,
        provenance: SharedInterjectionProvenance
    ) {
        self.id = id
        self.kind = kind
        self.approvedTranscript = approvedTranscript
        self.assetId = assetId
        self.provenance = provenance
    }
}

public struct SharedInterjectionPackageRecord: Codable, Equatable, Sendable {
    public let packageScopedId: String
    public let createdAt: Date
    public let anchor: PortableAnchorEvidence
    public let defaultRepresentationId: String
    public let representations: [SharedInterjectionRepresentation]

    public init(
        packageScopedId: String,
        createdAt: Date,
        anchor: PortableAnchorEvidence,
        defaultRepresentationId: String,
        representations: [SharedInterjectionRepresentation]
    ) {
        self.packageScopedId = packageScopedId
        self.createdAt = createdAt
        self.anchor = anchor
        self.defaultRepresentationId = defaultRepresentationId
        self.representations = representations
    }

    public var defaultRepresentation: SharedInterjectionRepresentation? {
        representations.first { $0.id == defaultRepresentationId }
    }
}

public struct SharedCommentaryLayerArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.commentary-layer.v1"

    public let id: String
    public let schemaVersion: String
    public let interjections: [SharedInterjectionPackageRecord]

    public init(
        id: String,
        schemaVersion: String = SharedCommentaryLayerArtifact.schemaVersion,
        interjections: [SharedInterjectionPackageRecord]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.interjections = interjections
    }
}

public enum PortableSceneEligibility: String, Codable, Equatable, Sendable {
    case eligible
    case excluded
    case unknown
}

public enum PortableSummaryProvenance: String, Codable, Equatable, Sendable {
    case publisherSupplied = "publisher_supplied"
    case senderAuthored = "sender_authored"
    case deterministic
    case modelGenerated = "model_generated"
}

public struct PortableListeningMapScene: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let order: Int
    public let title: String?
    public let summaryText: String?
    public let summaryAssetId: String?
    public let summaryProvenance: PortableSummaryProvenance?
    public let eligibility: PortableSceneEligibility
    public let eligibilityReason: String?
    public let startAnchor: PortableAnchorEvidence
    public let endAnchor: PortableAnchorEvidence

    public init(
        id: String,
        order: Int,
        title: String? = nil,
        summaryText: String? = nil,
        summaryAssetId: String? = nil,
        summaryProvenance: PortableSummaryProvenance? = nil,
        eligibility: PortableSceneEligibility,
        eligibilityReason: String? = nil,
        startAnchor: PortableAnchorEvidence,
        endAnchor: PortableAnchorEvidence
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.summaryText = summaryText
        self.summaryAssetId = summaryAssetId
        self.summaryProvenance = summaryProvenance
        self.eligibility = eligibility
        self.eligibilityReason = eligibilityReason
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
    }
}

public struct PortableListeningMapProposalArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.listening-map-proposal.v2"

    public let id: String
    public let schemaVersion: String
    public let languageCode: String?
    public let createdAt: Date
    public let generator: String
    public let scenes: [PortableListeningMapScene]

    public init(
        id: String,
        schemaVersion: String = PortableListeningMapProposalArtifact.schemaVersion,
        languageCode: String? = nil,
        createdAt: Date,
        generator: String,
        scenes: [PortableListeningMapScene]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.languageCode = languageCode
        self.createdAt = createdAt
        self.generator = generator
        self.scenes = scenes
    }
}

public struct EmbeddedTextItemArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.embedded-text-item.v1"

    public let id: String
    public let schemaVersion: String
    public let originalMediaType: String
    public let text: String

    public init(
        id: String = "embedded-item",
        schemaVersion: String = EmbeddedTextItemArtifact.schemaVersion,
        originalMediaType: String,
        text: String
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.originalMediaType = originalMediaType
        self.text = text
    }
}

public enum SpokenMarginsArtifactKind {
    public static let commentaryLayer = "commentary_layer"
    public static let listeningMapProposal = "listening_map_proposal"
    public static let editionFingerprintSpine = "edition_fingerprint_spine"
    public static let transcriptPhraseSketch = "transcript_phrase_sketch"
    public static let embeddedTextItem = "embedded_text_item"
    public static let conversation = "conversation"
}

public struct SpokenMarginsArtifactDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let schemaVersion: String
    public let path: String
    public let required: Bool
    public var byteCount: Int?
    public var sha256: String?

    public init(
        id: String,
        kind: String,
        schemaVersion: String,
        path: String,
        required: Bool,
        byteCount: Int? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.path = path
        self.required = required
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum SpokenMarginsAssetRole {
    public static let originalVoice = "original_voice"
    public static let cleanedVoice = "cleaned_voice"
    public static let summaryVoice = "summary_voice"
    public static let ttsVoice = "tts_voice"
    public static let acousticSignature = "acoustic_signature"
}

public struct SpokenMarginsAssetDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let path: String
    public let mimeType: String
    public let durationMs: Int?
    /// Media anchor time relative to the beginning of this evidence clip. This
    /// may be negative for an evidence flank that begins after the anchor.
    public let anchorOffsetMs: Int?
    public let provenance: String
    public var byteCount: Int?
    public var sha256: String?

    public init(
        id: String,
        role: String,
        path: String,
        mimeType: String,
        durationMs: Int? = nil,
        anchorOffsetMs: Int? = nil,
        provenance: String,
        byteCount: Int? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.role = role
        self.path = path
        self.mimeType = mimeType
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
        self.provenance = provenance
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct InterjectionPackageRedactions: Codable, Equatable, Sendable {
    public let rawAudioOmitted: Bool
    public let rawTranscriptOmitted: Bool
    public let fullItemOmitted: Bool
    public let itemAudioOmitted: Bool
    public let diagnosticsOmitted: Bool
    public let filesystemPathsOmitted: Bool
    public let unrelatedTurnsOmitted: Bool
    public let privateRepresentationsOmitted: Bool

    public init(
        rawAudioOmitted: Bool = true,
        rawTranscriptOmitted: Bool = true,
        fullItemOmitted: Bool = true,
        itemAudioOmitted: Bool = true,
        diagnosticsOmitted: Bool = true,
        filesystemPathsOmitted: Bool = true,
        unrelatedTurnsOmitted: Bool = true,
        privateRepresentationsOmitted: Bool = true
    ) {
        self.rawAudioOmitted = rawAudioOmitted
        self.rawTranscriptOmitted = rawTranscriptOmitted
        self.fullItemOmitted = fullItemOmitted
        self.itemAudioOmitted = itemAudioOmitted
        self.diagnosticsOmitted = diagnosticsOmitted
        self.filesystemPathsOmitted = filesystemPathsOmitted
        self.unrelatedTurnsOmitted = unrelatedTurnsOmitted
        self.privateRepresentationsOmitted = privateRepresentationsOmitted
    }

    @available(*, deprecated, message: "Use itemAudioOmitted; a source is a feed, while this flag describes the listened-to item's audio.")
    public init(
        rawAudioOmitted: Bool,
        rawTranscriptOmitted: Bool,
        fullItemOmitted: Bool,
        sourceAudioOmitted: Bool,
        diagnosticsOmitted: Bool,
        filesystemPathsOmitted: Bool,
        unrelatedTurnsOmitted: Bool,
        privateRepresentationsOmitted: Bool
    ) {
        self.init(
            rawAudioOmitted: rawAudioOmitted,
            rawTranscriptOmitted: rawTranscriptOmitted,
            fullItemOmitted: fullItemOmitted,
            itemAudioOmitted: sourceAudioOmitted,
            diagnosticsOmitted: diagnosticsOmitted,
            filesystemPathsOmitted: filesystemPathsOmitted,
            unrelatedTurnsOmitted: unrelatedTurnsOmitted,
            privateRepresentationsOmitted: privateRepresentationsOmitted
        )
    }

    public var provesPrivateMinimization: Bool {
        rawAudioOmitted
            && rawTranscriptOmitted
            && itemAudioOmitted
            && diagnosticsOmitted
            && filesystemPathsOmitted
            && unrelatedTurnsOmitted
            && privateRepresentationsOmitted
    }
}

public struct SpokenMarginsPackageManifest: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let packageId: String
    public let createdAt: Date
    public var contentDigest: String?
    public let item: SharedItemIdentity
    public let itemTransport: SharedItemTransport
    public let senderDisplayLabel: String?
    public let suggestedRevealMode: ImportedCommentaryRevealMode?
    public let requiredCapabilities: [String]
    public var artifacts: [SpokenMarginsArtifactDescriptor]
    public var assets: [SpokenMarginsAssetDescriptor]
    public let redactions: InterjectionPackageRedactions

    public init(
        schemaVersion: String = "spoken-margins.package.v1",
        packageId: String,
        createdAt: Date,
        contentDigest: String? = nil,
        item: SharedItemIdentity,
        itemTransport: SharedItemTransport,
        senderDisplayLabel: String? = nil,
        suggestedRevealMode: ImportedCommentaryRevealMode? = nil,
        requiredCapabilities: [String] = [SharedCommentaryLayerArtifact.schemaVersion],
        artifacts: [SpokenMarginsArtifactDescriptor],
        assets: [SpokenMarginsAssetDescriptor] = [],
        redactions: InterjectionPackageRedactions = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.packageId = packageId
        self.createdAt = createdAt
        self.contentDigest = contentDigest
        self.item = item
        self.itemTransport = itemTransport
        self.senderDisplayLabel = senderDisplayLabel
        self.suggestedRevealMode = suggestedRevealMode
        self.requiredCapabilities = requiredCapabilities
        self.artifacts = artifacts
        self.assets = assets
        self.redactions = redactions
    }
}

public struct PreparedSpokenMarginsPackage: Sendable {
    public let manifest: SpokenMarginsPackageManifest
    public let artifactData: [String: Data]
    public let assetFiles: [String: URL]

    public init(
        manifest: SpokenMarginsPackageManifest,
        artifactData: [String: Data],
        assetFiles: [String: URL]
    ) {
        self.manifest = manifest
        self.artifactData = artifactData
        self.assetFiles = assetFiles
    }
}
