import CryptoKit
import Foundation

public enum EpisodeFingerprintProvenance: String, Codable, Equatable, Sendable {
    case observedDecodedPlayback = "observed_decoded_playback"
    case sourceWindowReference = "source_window_reference"
    case downloadedSourceReference = "downloaded_source_reference"
}

public enum EpisodeFingerprintTrigger: String, Codable, Equatable, Sendable {
    case initialPlayback = "initial_playback"
    case periodicPlayback = "periodic_playback"
    case preInterjection = "pre_interjection"
    case postInterjectionResume = "post_interjection_resume"
    case stablePostSeek = "stable_post_seek"
    case downloadedPreparation = "downloaded_preparation"
}

public struct EpisodeFingerprintLandmark: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let order: Int
    public let sourceMediaStartMs: Int
    public let sourceMediaEndMs: Int
    public let anchorMediaTimeMs: Int
    public let continuityEpoch: Int
    public let trigger: EpisodeFingerprintTrigger
    public let provenance: EpisodeFingerprintProvenance
    public let signatureAssetId: String
    public let transcriptSketchWindowId: String?
    public let generatorVersion: String

    public init(
        id: String,
        order: Int,
        sourceMediaStartMs: Int,
        sourceMediaEndMs: Int,
        anchorMediaTimeMs: Int,
        continuityEpoch: Int,
        trigger: EpisodeFingerprintTrigger,
        provenance: EpisodeFingerprintProvenance,
        signatureAssetId: String,
        transcriptSketchWindowId: String? = nil,
        generatorVersion: String = "shazamkit-landmark.v1"
    ) {
        self.id = id
        self.order = max(0, order)
        self.sourceMediaStartMs = max(0, sourceMediaStartMs)
        self.sourceMediaEndMs = max(sourceMediaStartMs, sourceMediaEndMs)
        self.anchorMediaTimeMs = max(0, anchorMediaTimeMs)
        self.continuityEpoch = max(0, continuityEpoch)
        self.trigger = trigger
        self.provenance = provenance
        self.signatureAssetId = signatureAssetId
        self.transcriptSketchWindowId = transcriptSketchWindowId
        self.generatorVersion = generatorVersion
    }
}

public struct EditionFingerprintSpineArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.edition-fingerprint-spine.v1"

    public let id: String
    public let schemaVersion: String
    public let itemId: String
    public let canonicalURL: String?
    public let episodeGUID: String?
    public let producingEditionDurationMs: Int?
    public let producingEditionSHA256: String?
    public let createdAt: Date
    public let generatorVersion: String
    public let landmarks: [EpisodeFingerprintLandmark]

    public init(
        id: String,
        schemaVersion: String = EditionFingerprintSpineArtifact.schemaVersion,
        itemId: String,
        canonicalURL: String? = nil,
        episodeGUID: String? = nil,
        producingEditionDurationMs: Int? = nil,
        producingEditionSHA256: String? = nil,
        createdAt: Date = Date(),
        generatorVersion: String = "edition-fingerprint-spine.v1",
        landmarks: [EpisodeFingerprintLandmark]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.canonicalURL = canonicalURL
        self.episodeGUID = episodeGUID
        self.producingEditionDurationMs = producingEditionDurationMs.map { max(0, $0) }
        self.producingEditionSHA256 = producingEditionSHA256
        self.createdAt = createdAt
        self.generatorVersion = generatorVersion
        self.landmarks = landmarks.sorted {
            $0.order == $1.order ? $0.sourceMediaStartMs < $1.sourceMediaStartMs : $0.order < $1.order
        }
    }
}

public struct TranscriptPhraseSketchWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceStartMs: Int
    public let sourceEndMs: Int
    public let hashes: [String]

    public init(id: String, sourceStartMs: Int, sourceEndMs: Int, hashes: [String]) {
        self.id = id
        self.sourceStartMs = max(0, sourceStartMs)
        self.sourceEndMs = max(sourceStartMs, sourceEndMs)
        self.hashes = Array(Set(hashes)).sorted()
    }
}

public struct TranscriptPhraseSketchArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.transcript-phrase-sketch.v1"

    public let id: String
    public let schemaVersion: String
    public let itemId: String
    public let languageCode: String?
    public let saltBase64: String
    public let normalizationVersion: String
    public let shingleWidth: Int
    public let maximumHashesPerWindow: Int
    public let createdAt: Date
    public let windows: [TranscriptPhraseSketchWindow]

    public init(
        id: String,
        schemaVersion: String = TranscriptPhraseSketchArtifact.schemaVersion,
        itemId: String,
        languageCode: String? = nil,
        saltBase64: String,
        normalizationVersion: String = "phrase-sketch-normalization.v1",
        shingleWidth: Int = 3,
        maximumHashesPerWindow: Int = 24,
        createdAt: Date = Date(),
        windows: [TranscriptPhraseSketchWindow]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.languageCode = languageCode
        self.saltBase64 = saltBase64
        self.normalizationVersion = normalizationVersion
        self.shingleWidth = shingleWidth
        self.maximumHashesPerWindow = maximumHashesPerWindow
        self.createdAt = createdAt
        self.windows = windows.sorted { $0.sourceStartMs < $1.sourceStartMs }
    }
}

/// Phrase sketches are compact matching aids, not a privacy boundary. A public
/// per-map salt prevents cross-map equality but cannot prevent dictionary attacks.
public enum TranscriptPhraseSketchBuilder {
    public static let windowDurationMs = 30_000
    public static let shingleWidth = 3
    public static let maximumHashesPerWindow = 24

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "had", "has", "have", "he", "her", "his", "i", "if", "in", "is", "it",
        "its", "not", "of", "on", "or", "our", "she", "so", "that", "the", "their",
        "they", "this", "to", "was", "we", "were", "with", "you", "your"
    ]

    public static func makeArtifact(
        id: String,
        itemId: String,
        timeline: TranscriptTimeline,
        languageCode: String? = nil,
        salt: Data? = nil,
        createdAt: Date = Date()
    ) -> TranscriptPhraseSketchArtifact {
        let resolvedSalt = salt ?? randomSalt()
        let duration = max(
            timeline.durationMs ?? 0,
            timeline.segments.map(\.endMs).max() ?? 0
        )
        var windows: [TranscriptPhraseSketchWindow] = []
        var start = 0
        while start < duration {
            let end = min(duration, start + windowDurationMs)
            let text = timeline.segments
                .filter { $0.endMs > start && $0.startMs < end }
                .map(\.text)
                .joined(separator: " ")
            let hashes = hashes(for: text, salt: resolvedSalt)
            if !hashes.isEmpty {
                windows.append(TranscriptPhraseSketchWindow(
                    id: "\(id)-window-\(String(format: "%06d", start / 1_000))",
                    sourceStartMs: start,
                    sourceEndMs: end,
                    hashes: hashes
                ))
            }
            start = end
        }
        return TranscriptPhraseSketchArtifact(
            id: id,
            itemId: itemId,
            languageCode: languageCode,
            saltBase64: resolvedSalt.base64EncodedString(),
            createdAt: createdAt,
            windows: windows
        )
    }

    public static func hashes(for text: String, salt: Data) -> [String] {
        let tokens = normalizedTokens(text)
        guard tokens.count >= shingleWidth else { return [] }
        let key = SymmetricKey(data: salt)
        var values = Set<String>()
        for index in 0...(tokens.count - shingleWidth) {
            let shingle = Array(tokens[index..<(index + shingleWidth)])
            guard shingle.contains(where: { !stopwords.contains($0) }) else { continue }
            let code = HMAC<SHA256>.authenticationCode(
                for: Data(shingle.joined(separator: " ").utf8),
                using: key
            )
            values.insert(code.prefix(16).map { String(format: "%02x", $0) }.joined())
        }
        let sorted = Array(values).sorted()
        return Array(sorted.prefix(maximumHashesPerWindow))
    }

    public static func overlapScore(_ lhs: [String], _ rhs: [String]) -> Double {
        let left = Set(lhs)
        let right = Set(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    public static func normalizedTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes)
    }
}

public enum ResolvedListeningMapConfidence: String, Codable, Equatable, Sendable {
    case exactEdition = "exact_edition"
    case verified
    case approximate
    case unresolved
}

public struct ResolvedListeningMapPoint: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceMediaTimeMs: Int
    public let recipientMediaTimeMs: Int?
    public let confidence: ResolvedListeningMapConfidence
    public let evidenceIds: [String]

    public init(
        id: String,
        sourceMediaTimeMs: Int,
        recipientMediaTimeMs: Int?,
        confidence: ResolvedListeningMapConfidence,
        evidenceIds: [String]
    ) {
        self.id = id
        self.sourceMediaTimeMs = max(0, sourceMediaTimeMs)
        self.recipientMediaTimeMs = recipientMediaTimeMs.map { max(0, $0) }
        self.confidence = confidence
        self.evidenceIds = evidenceIds
    }
}

public struct ResolvedListeningMapInterval: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceStartMs: Int
    public let sourceEndMs: Int
    public let recipientStartMs: Int?
    public let recipientEndMs: Int?
    public let isStable: Bool
    public let reason: String

    public init(
        id: String,
        sourceStartMs: Int,
        sourceEndMs: Int,
        recipientStartMs: Int?,
        recipientEndMs: Int?,
        isStable: Bool,
        reason: String
    ) {
        self.id = id
        self.sourceStartMs = max(0, sourceStartMs)
        self.sourceEndMs = max(sourceStartMs, sourceEndMs)
        self.recipientStartMs = recipientStartMs.map { max(0, $0) }
        self.recipientEndMs = recipientEndMs.map { max(0, $0) }
        self.isStable = isStable
        self.reason = reason
    }
}

public struct ResolvedListeningMapProjection: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "resolved-listening-map-projection.v1"

    public let id: String
    public let schemaVersion: String
    public let itemId: String
    public let proposalId: String?
    public let recipientEditionSHA256: String?
    public let createdAt: Date
    public let algorithmVersion: String
    public let points: [ResolvedListeningMapPoint]
    public let intervals: [ResolvedListeningMapInterval]

    public init(
        id: String,
        schemaVersion: String = ResolvedListeningMapProjection.schemaVersion,
        itemId: String,
        proposalId: String? = nil,
        recipientEditionSHA256: String? = nil,
        createdAt: Date = Date(),
        algorithmVersion: String = "episode-projection.v1",
        points: [ResolvedListeningMapPoint],
        intervals: [ResolvedListeningMapInterval]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.proposalId = proposalId
        self.recipientEditionSHA256 = recipientEditionSHA256
        self.createdAt = createdAt
        self.algorithmVersion = algorithmVersion
        self.points = points.sorted { $0.sourceMediaTimeMs < $1.sourceMediaTimeMs }
        self.intervals = intervals.sorted { $0.sourceStartMs < $1.sourceStartMs }
    }

    public func projectedRecipientTime(for sourceMediaTimeMs: Int) -> Int? {
        if algorithmVersion == "episode-projection.exact-edition.v1" {
            return max(0, sourceMediaTimeMs)
        }
        if let exact = points.first(where: { $0.sourceMediaTimeMs == sourceMediaTimeMs && $0.confidence != .unresolved }) {
            return exact.recipientMediaTimeMs
        }
        guard let interval = intervals.first(where: {
            $0.isStable && sourceMediaTimeMs >= $0.sourceStartMs && sourceMediaTimeMs <= $0.sourceEndMs
        }), let recipientStart = interval.recipientStartMs, let recipientEnd = interval.recipientEndMs else {
            return nil
        }
        let sourceWidth = max(1, interval.sourceEndMs - interval.sourceStartMs)
        let fraction = Double(sourceMediaTimeMs - interval.sourceStartMs) / Double(sourceWidth)
        return max(0, recipientStart + Int((Double(recipientEnd - recipientStart) * fraction).rounded()))
    }
}

public struct FingerprintLandmarkMatch: Equatable, Sendable, Identifiable {
    public let id: String
    public let landmarkId: String
    public let sourceMediaTimeMs: Int
    public let recipientMediaTimeMs: Int
    public let acousticConfidence: Double
    public let transcriptCorroborated: Bool
    public let isUniqueWithinEpisode: Bool

    public init(
        id: String,
        landmarkId: String,
        sourceMediaTimeMs: Int,
        recipientMediaTimeMs: Int,
        acousticConfidence: Double,
        transcriptCorroborated: Bool,
        isUniqueWithinEpisode: Bool
    ) {
        self.id = id
        self.landmarkId = landmarkId
        self.sourceMediaTimeMs = max(0, sourceMediaTimeMs)
        self.recipientMediaTimeMs = max(0, recipientMediaTimeMs)
        self.acousticConfidence = min(1, max(0, acousticConfidence))
        self.transcriptCorroborated = transcriptCorroborated
        self.isUniqueWithinEpisode = isUniqueWithinEpisode
    }

    fileprivate var weight: Double {
        acousticConfidence + (transcriptCorroborated ? 1 : 0) + (isUniqueWithinEpisode ? 0.5 : 0)
    }
}

public enum EpisodeFingerprintAlignment {
    public static let maximumStableOffsetDeltaMs = 1_000
    public static let minimumStableSlope = 0.998
    public static let maximumStableSlope = 1.002

    /// Returns the maximum-weight strictly order-preserving sequence. This is
    /// deliberately conservative: repeated or contradictory candidates are
    /// allowed to fall out of the verified chain instead of forcing placement.
    public static func maximumWeightMonotonicMatches(
        _ matches: [FingerprintLandmarkMatch]
    ) -> [FingerprintLandmarkMatch] {
        let sorted = matches.sorted {
            if $0.sourceMediaTimeMs != $1.sourceMediaTimeMs { return $0.sourceMediaTimeMs < $1.sourceMediaTimeMs }
            if $0.recipientMediaTimeMs != $1.recipientMediaTimeMs { return $0.recipientMediaTimeMs < $1.recipientMediaTimeMs }
            return $0.id < $1.id
        }
        guard !sorted.isEmpty else { return [] }
        var score = sorted.map(\.weight)
        var predecessor = [Int?](repeating: nil, count: sorted.count)
        for index in sorted.indices {
            for prior in 0..<index where
                sorted[prior].sourceMediaTimeMs < sorted[index].sourceMediaTimeMs
                    && sorted[prior].recipientMediaTimeMs < sorted[index].recipientMediaTimeMs {
                let candidate = score[prior] + sorted[index].weight
                if candidate > score[index] {
                    score[index] = candidate
                    predecessor[index] = prior
                }
            }
        }
        var cursor = score.indices.max { score[$0] < score[$1] }
        var result: [FingerprintLandmarkMatch] = []
        while let index = cursor {
            result.append(sorted[index])
            cursor = predecessor[index]
        }
        return result.reversed()
    }

    public static func makeProjection(
        id: String,
        itemId: String,
        proposalId: String? = nil,
        recipientEditionSHA256: String? = nil,
        matches: [FingerprintLandmarkMatch],
        exactEdition: Bool = false,
        createdAt: Date = Date()
    ) -> ResolvedListeningMapProjection {
        let chain = maximumWeightMonotonicMatches(matches)
        let points = chain.enumerated().map { index, match in
            // Acoustic uniqueness helps choose among candidates, but is not an
            // independent evidence layer. Verification requires transcript
            // agreement or another order-preserving direct landmark.
            let hasMonotonicNeighbor = index > 0 || index + 1 < chain.count
            let independentlyCorroborated = match.transcriptCorroborated || hasMonotonicNeighbor
            return ResolvedListeningMapPoint(
                id: match.landmarkId,
                sourceMediaTimeMs: match.sourceMediaTimeMs,
                recipientMediaTimeMs: match.recipientMediaTimeMs,
                confidence: exactEdition ? .exactEdition : (independentlyCorroborated ? .verified : .approximate),
                evidenceIds: [match.id]
            )
        }
        var intervals: [ResolvedListeningMapInterval] = []
        for (index, pair) in zip(chain, chain.dropFirst()).enumerated() {
            let sourceWidth = pair.1.sourceMediaTimeMs - pair.0.sourceMediaTimeMs
            let recipientWidth = pair.1.recipientMediaTimeMs - pair.0.recipientMediaTimeMs
            let slope = sourceWidth > 0 ? Double(recipientWidth) / Double(sourceWidth) : 0
            let firstOffset = pair.0.recipientMediaTimeMs - pair.0.sourceMediaTimeMs
            let secondOffset = pair.1.recipientMediaTimeMs - pair.1.sourceMediaTimeMs
            // Interpolation is stricter than direct landmark placement: both
            // acoustic brackets must also carry local transcript agreement.
            let stable = pair.0.transcriptCorroborated
                && pair.1.transcriptCorroborated
                && abs(secondOffset - firstOffset) <= maximumStableOffsetDeltaMs
                && (minimumStableSlope...maximumStableSlope).contains(slope)
            intervals.append(ResolvedListeningMapInterval(
                id: "interval-\(index)",
                sourceStartMs: pair.0.sourceMediaTimeMs,
                sourceEndMs: pair.1.sourceMediaTimeMs,
                recipientStartMs: pair.0.recipientMediaTimeMs,
                recipientEndMs: pair.1.recipientMediaTimeMs,
                isStable: stable,
                reason: stable ? "stable_ordered_landmarks" : "edition_change_or_insufficient_corroboration"
            ))
        }
        return ResolvedListeningMapProjection(
            id: id,
            itemId: itemId,
            proposalId: proposalId,
            recipientEditionSHA256: recipientEditionSHA256,
            createdAt: createdAt,
            algorithmVersion: exactEdition
                ? "episode-projection.exact-edition.v1"
                : "episode-projection.v1",
            points: points,
            intervals: intervals
        )
    }
}

public struct SparseFingerprintSchedule: Codable, Equatable, Sendable {
    public static let initialMediaTimeMs = 60_000
    public static let periodicIntervalMs = 300_000
    public static let targetDurationMs = 12_000
    public static let seekDebounceMs = 5_000

    public private(set) var continuityEpoch: Int
    public private(set) var capturedGridIndices: Set<Int>
    public private(set) var lastSeekAt: Date?

    public init(continuityEpoch: Int = 0, capturedGridIndices: Set<Int> = [], lastSeekAt: Date? = nil) {
        self.continuityEpoch = max(0, continuityEpoch)
        self.capturedGridIndices = capturedGridIndices
        self.lastSeekAt = lastSeekAt
    }

    public mutating func noteSeek(at date: Date) {
        continuityEpoch += 1
        lastSeekAt = date
    }

    public func isSeekStable(at date: Date) -> Bool {
        guard let lastSeekAt else { return true }
        return date.timeIntervalSince(lastSeekAt) * 1_000 >= Double(Self.seekDebounceMs)
    }

    public func dueGridIndex(at mediaTimeMs: Int) -> Int? {
        guard mediaTimeMs >= Self.initialMediaTimeMs else { return nil }
        let index = (mediaTimeMs - Self.initialMediaTimeMs) / Self.periodicIntervalMs
        return capturedGridIndices.contains(index) ? nil : index
    }

    public mutating func markCaptured(gridIndex: Int) {
        capturedGridIndices.insert(max(0, gridIndex))
    }
}

public enum EpisodeMapPreparationStage: String, Codable, CaseIterable, Equatable, Sendable {
    case verifySource = "verify_source"
    case generateFingerprintSpine = "generate_fingerprint_spine"
    case transcribe
    case generatePhraseSketch = "generate_phrase_sketch"
    case segmentScenes = "segment_scenes"
    case generateSummaries = "generate_summaries"
    case renderBridges = "render_bridges"
    case commit
    case completed
}

public enum AutomaticEpisodeMapPreparationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case whileCharging = "while_charging"

    public var displayName: String { self == .off ? "Off" : "While Charging" }
}

public struct EpisodeMapPreparationJob: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "episode-map-preparation-job.v1"

    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var policy: PreparationJobPolicy
    public var requestedAt: Date
    public var stage: EpisodeMapPreparationStage
    public var nextUnitIndex: Int
    public var transientTranscriptRelativePath: String?
    public var isCancelled: Bool
    public var lastFailureCode: String?

    public init(
        schemaVersion: String = EpisodeMapPreparationJob.schemaVersion,
        id: String,
        itemId: String,
        policy: PreparationJobPolicy,
        requestedAt: Date = Date(),
        stage: EpisodeMapPreparationStage = .verifySource,
        nextUnitIndex: Int = 0,
        transientTranscriptRelativePath: String? = nil,
        isCancelled: Bool = false,
        lastFailureCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.itemId = itemId
        self.policy = policy
        self.requestedAt = requestedAt
        self.stage = stage
        self.nextUnitIndex = max(0, nextUnitIndex)
        self.transientTranscriptRelativePath = transientTranscriptRelativePath
        self.isCancelled = isCancelled
        self.lastFailureCode = lastFailureCode
    }
}

public struct EpisodeSceneDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let order: Int
    public let startMs: Int
    public let endMs: Int
    public let startTranscriptSegmentId: String?
    public let endTranscriptSegmentId: String?
    public let publisherTitle: String?

    public init(
        id: String,
        order: Int,
        startMs: Int,
        endMs: Int,
        startTranscriptSegmentId: String?,
        endTranscriptSegmentId: String?,
        publisherTitle: String? = nil
    ) {
        self.id = id
        self.order = order
        self.startMs = max(0, startMs)
        self.endMs = max(startMs, endMs)
        self.startTranscriptSegmentId = startTranscriptSegmentId
        self.endTranscriptSegmentId = endTranscriptSegmentId
        self.publisherTitle = publisherTitle
    }
}

public enum SkimDirection: String, Codable, Equatable, Sendable {
    case forward
    case backward
}

public enum SkimBridgeStatus: String, Codable, Equatable, Sendable {
    case preparing
    case playing
    case paused
    case completing
    case cancelled
}

public struct SkimBridgeState: Codable, Equatable, Sendable {
    public let direction: SkimDirection
    public let itemId: String
    public let originMediaTimeMs: Int
    public let summarySceneId: String
    public let destinationSceneId: String?
    public let destinationMediaTimeMs: Int
    public let summaryAssetId: String
    public let wasSourcePlaying: Bool
    public var status: SkimBridgeStatus

    public init(
        direction: SkimDirection,
        itemId: String,
        originMediaTimeMs: Int,
        summarySceneId: String,
        destinationSceneId: String?,
        destinationMediaTimeMs: Int,
        summaryAssetId: String,
        wasSourcePlaying: Bool,
        status: SkimBridgeStatus
    ) {
        self.direction = direction
        self.itemId = itemId
        self.originMediaTimeMs = max(0, originMediaTimeMs)
        self.summarySceneId = summarySceneId
        self.destinationSceneId = destinationSceneId
        self.destinationMediaTimeMs = max(0, destinationMediaTimeMs)
        self.summaryAssetId = summaryAssetId
        self.wasSourcePlaying = wasSourcePlaying
        self.status = status
    }
}

public enum EpisodeSceneSegmenter {
    public static let targetDurationMs = 240_000
    public static let minimumDurationMs = 90_000
    public static let maximumDurationMs = 480_000
    public static let boundarySnapToleranceMs = 15_000

    public static func makeDrafts(timeline: TranscriptTimeline) -> [EpisodeSceneDraft] {
        let segments = timeline.segments.sorted { $0.startMs < $1.startMs }
        let duration = max(timeline.durationMs ?? 0, segments.last?.endMs ?? 0)
        guard duration > 0 else { return [] }
        if !timeline.chapters.isEmpty {
            let chapters = timeline.chapters.sorted { $0.startMs < $1.startMs }
            var drafts: [EpisodeSceneDraft] = []
            for (chapterIndex, chapter) in chapters.enumerated() {
                let end = chapterIndex + 1 < chapters.count ? chapters[chapterIndex + 1].startMs : duration
                drafts.append(contentsOf: split(
                    startMs: chapter.startMs,
                    endMs: end,
                    publisherTitle: chapter.title,
                    idPrefix: chapter.id,
                    startingOrder: drafts.count,
                    segments: segments
                ))
            }
            return drafts
        }
        return split(
            startMs: 0,
            endMs: duration,
            publisherTitle: nil,
            idPrefix: "generated",
            startingOrder: 0,
            segments: segments
        )
    }

    private static func split(
        startMs: Int,
        endMs: Int,
        publisherTitle: String?,
        idPrefix: String,
        startingOrder: Int,
        segments: [MediaTimelineSegment]
    ) -> [EpisodeSceneDraft] {
        guard endMs > startMs else { return [] }
        if endMs - startMs <= maximumDurationMs {
            return [draft(
                id: "\(idPrefix)-scene-1",
                order: startingOrder,
                startMs: startMs,
                endMs: endMs,
                publisherTitle: publisherTitle,
                segments: segments
            )]
        }
        var boundaries = [startMs]
        var cursor = startMs
        while endMs - cursor > maximumDurationMs {
            let desired = cursor + targetDurationMs
            let minimum = cursor + minimumDurationMs
            let maximum = min(endMs - minimumDurationMs, cursor + maximumDurationMs)
            let selected = bestTranscriptChangePoint(
                near: desired,
                minimum: minimum,
                maximum: maximum,
                segments: segments
            ) ?? min(maximum, max(minimum, desired))
            guard selected > cursor else { break }
            boundaries.append(selected)
            cursor = selected
        }
        boundaries.append(endMs)
        return zip(boundaries, boundaries.dropFirst()).enumerated().map { index, pair in
            draft(
                id: "\(idPrefix)-scene-\(index + 1)",
                order: startingOrder + index,
                startMs: pair.0,
                endMs: pair.1,
                publisherTitle: publisherTitle,
                segments: segments
            )
        }
    }

    private static func draft(
        id: String,
        order: Int,
        startMs: Int,
        endMs: Int,
        publisherTitle: String?,
        segments: [MediaTimelineSegment]
    ) -> EpisodeSceneDraft {
        let contained = segments.filter { $0.endMs > startMs && $0.startMs < endMs }
        return EpisodeSceneDraft(
            id: id,
            order: order,
            startMs: startMs,
            endMs: endMs,
            startTranscriptSegmentId: contained.first?.id,
            endTranscriptSegmentId: contained.last?.id,
            publisherTitle: publisherTitle
        )
    }

    private static func bestTranscriptChangePoint(
        near desired: Int,
        minimum: Int,
        maximum: Int,
        segments: [MediaTimelineSegment]
    ) -> Int? {
        let candidates = segments.indices.filter { index in
            let start = segments[index].startMs
            return start >= minimum
                && start <= maximum
                && abs(start - desired) <= boundarySnapToleranceMs
        }
        return candidates.max { lhs, rhs in
            let left = changePointScore(at: lhs, desired: desired, segments: segments)
            let right = changePointScore(at: rhs, desired: desired, segments: segments)
            if left != right { return left < right }
            let leftDistance = abs(segments[lhs].startMs - desired)
            let rightDistance = abs(segments[rhs].startMs - desired)
            if leftDistance != rightDistance { return leftDistance > rightDistance }
            return segments[lhs].startMs > segments[rhs].startMs
        }.map { segments[$0].startMs }
    }

    private static func changePointScore(
        at index: Int,
        desired: Int,
        segments: [MediaTimelineSegment]
    ) -> Double {
        let preceding = segments[max(0, index - 3)..<index]
        let followingEnd = min(segments.count, index + 3)
        let following = segments[index..<followingEnd]
        let before = Set(preceding.flatMap { normalizedWords(in: $0.text) })
        let after = Set(following.flatMap { normalizedWords(in: $0.text) })
        let union = before.union(after)
        let lexicalChange = union.isEmpty ? 0 : 1 - Double(before.intersection(after).count) / Double(union.count)
        let precedingEnd = index > 0 ? segments[index - 1].endMs : segments[index].startMs
        let silenceBonus = min(1, Double(max(0, segments[index].startMs - precedingEnd)) / 5_000)
        let distancePenalty = Double(abs(segments[index].startMs - desired))
            / Double(max(1, boundarySnapToleranceMs))
        return lexicalChange + (silenceBonus * 0.75) - (distancePenalty * 0.15)
    }

    private static func normalizedWords(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
