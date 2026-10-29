import Foundation

public struct TTSRenderSignature: Codable, Equatable, Hashable, Sendable {
    public var schemaVersion: String
    public var engine: String
    public var modelRevision: String
    public var assetManifestHash: String
    public var voiceStyleHash: String
    public var synthesisParametersHash: String
    public var normalizationVersion: String
    public var chunkingVersion: String
    public var manifestVersion: String
    public var digest: String

    public init(
        schemaVersion: String = "tts-render-signature.v1",
        engine: String,
        modelRevision: String,
        assetManifestHash: String,
        voiceStyleHash: String,
        synthesisParametersHash: String,
        normalizationVersion: String,
        chunkingVersion: String,
        manifestVersion: String = "prepared-audio-manifest.v1",
        digest: String
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.modelRevision = modelRevision
        self.assetManifestHash = assetManifestHash
        self.voiceStyleHash = voiceStyleHash
        self.synthesisParametersHash = synthesisParametersHash
        self.normalizationVersion = normalizationVersion
        self.chunkingVersion = chunkingVersion
        self.manifestVersion = manifestVersion
        self.digest = digest
    }
}

public enum PreparedAudioState: String, Codable, Equatable, Sendable {
    case notPrepared = "not_prepared"
    case preparing
    case pausedForThermal = "paused_for_thermal"
    case readyOffline = "ready_offline"
    case needsRepreparation = "needs_repreparation"
    case stopped
    case failed
}

public struct PreparedAudioChunk: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var index: Int
    public var sourceRange: SourceLocator
    public var relativePath: String
    public var byteCount: Int64
    public var checksumSHA256: String
    public var durationMs: Int
    public var committedAt: Date
    /// The engine that made this chunk when it isn't the manifest's own, for example the iOS voice
    /// standing in for a garbled Supertonic chunk (#311). Nil in chunks from earlier builds, and
    /// for chunks the manifest's engine made; Build 29's decoder ignores the field.
    public var engine: String?

    public init(
        id: String,
        index: Int,
        sourceRange: SourceLocator,
        relativePath: String,
        byteCount: Int64,
        checksumSHA256: String,
        durationMs: Int,
        committedAt: Date = Date(),
        engine: String? = nil
    ) {
        self.id = id
        self.index = index
        self.sourceRange = sourceRange
        self.relativePath = relativePath
        self.byteCount = max(0, byteCount)
        self.checksumSHA256 = checksumSHA256
        self.durationMs = max(0, durationMs)
        self.committedAt = committedAt
        self.engine = engine
    }
}

public struct PreparedAudioArtifact: Codable, Equatable, Sendable {
    public var relativePath: String
    public var byteCount: Int64
    public var checksumSHA256: String
    public var durationMs: Int
    public var mediaType: String

    public init(relativePath: String, byteCount: Int64, checksumSHA256: String, durationMs: Int, mediaType: String = "audio/mp4") {
        self.relativePath = relativePath
        self.byteCount = max(0, byteCount)
        self.checksumSHA256 = checksumSHA256
        self.durationMs = max(0, durationMs)
        self.mediaType = mediaType
    }
}

public struct PreparedAudioManifest: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var sourcePackageId: String
    public var signature: TTSRenderSignature
    public var state: PreparedAudioState
    public var plannedChunkCount: Int
    public var chunks: [PreparedAudioChunk]
    public var artifact: PreparedAudioArtifact?
    public var failureCode: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// The article plan's identity (NarrationChunkPlanner) of the text this audio was made from.
    /// Nil for manifests made before #312; Build 29's decoder ignores the field.
    public var articleIdentity: String?

    public init(
        schemaVersion: String = "prepared-audio-manifest.v1",
        id: String,
        itemId: String,
        sourcePackageId: String,
        signature: TTSRenderSignature,
        state: PreparedAudioState,
        plannedChunkCount: Int,
        chunks: [PreparedAudioChunk] = [],
        artifact: PreparedAudioArtifact? = nil,
        failureCode: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        articleIdentity: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.articleIdentity = articleIdentity
        self.itemId = itemId
        self.sourcePackageId = sourcePackageId
        self.signature = signature
        self.state = state
        self.plannedChunkCount = max(0, plannedChunkCount)
        self.chunks = chunks.sorted { $0.index < $1.index }
        self.artifact = artifact
        self.failureCode = failureCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var committedChunkCount: Int { chunks.count }
    public var progress: Double {
        guard plannedChunkCount > 0 else { return state == .readyOffline ? 1 : 0 }
        return min(1, Double(chunks.count) / Double(plannedChunkCount))
    }

    public var canStartPartialPlayback: Bool {
        let startupTarget = min(2, max(1, plannedChunkCount))
        return chunks.count >= startupTarget
    }
    public var advertisesCompleteDuration: Bool { state == .readyOffline && artifact != nil }
}

/// What the Library and the Preparing Audio lists read of a prepared-audio manifest: its state, plan and artifact,
/// and how many chunks are committed, without the chunk list itself (#2506). A manifest of a long article holds a
/// chunk record per paragraph run (paths, checksums, source ranges); the Library reloads on every playback change and
/// needs none of them, only how many of the first few exist. `SQLiteSessionStore.loadPreparedAudioManifestSummaries()`
/// cuts the chunks out in SQL, so they are never copied or decoded.
public struct PreparedAudioManifestSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var itemId: String
    public var signature: TTSRenderSignature
    public var state: PreparedAudioState
    public var plannedChunkCount: Int
    public var artifact: PreparedAudioArtifact?
    public var failureCode: String?
    public var updatedAt: Date
    /// The `index` of every committed chunk, in stored order.
    public var chunkIndexes: [Int]

    public init(
        id: String,
        itemId: String,
        signature: TTSRenderSignature,
        state: PreparedAudioState,
        plannedChunkCount: Int,
        artifact: PreparedAudioArtifact?,
        failureCode: String?,
        updatedAt: Date,
        chunkIndexes: [Int]
    ) {
        self.id = id
        self.itemId = itemId
        self.signature = signature
        self.state = state
        self.plannedChunkCount = plannedChunkCount
        self.artifact = artifact
        self.failureCode = failureCode
        self.updatedAt = updatedAt
        self.chunkIndexes = chunkIndexes
    }

    public init(_ manifest: PreparedAudioManifest) {
        self.init(
            id: manifest.id, itemId: manifest.itemId, signature: manifest.signature, state: manifest.state,
            plannedChunkCount: manifest.plannedChunkCount, artifact: manifest.artifact,
            failureCode: manifest.failureCode, updatedAt: manifest.updatedAt,
            chunkIndexes: manifest.chunks.map(\.index))
    }

    /// `PreparedAudioManifest.committedChunkCount`.
    public var committedChunkCount: Int { chunkIndexes.count }

    /// How many committed chunks sit before chunk `target`: the opening buffer's progress.
    public func committedChunkCount(before target: Int) -> Int { chunkIndexes.filter { $0 < target }.count }
}

extension PreparedAudioManifest {
    public var summary: PreparedAudioManifestSummary { PreparedAudioManifestSummary(self) }
}

public enum PreparedAudioLocatorMapper {
    public static func mediaTimeMs(for locator: SourceLocator, chunks: [PreparedAudioChunk]) -> Int? {
        var elapsed = 0
        for chunk in chunks.sorted(by: { $0.index < $1.index }) {
            let range = chunk.sourceRange
            guard range.documentId == locator.documentId else {
                elapsed += chunk.durationMs
                continue
            }
            if locator.utf8Start <= range.utf8End, locator.utf8End >= range.utf8Start {
                let width = max(1, range.utf8End - range.utf8Start)
                let offset = min(width, max(0, locator.utf8Start - range.utf8Start))
                return elapsed + Int((Double(offset) / Double(width) * Double(chunk.durationMs)).rounded())
            }
            elapsed += chunk.durationMs
        }
        return nil
    }

    public static func sourceLocator(at mediaTimeMs: Int, chunks: [PreparedAudioChunk]) -> SourceLocator? {
        let ordered = chunks.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else { return nil }
        var elapsed = 0
        for chunk in ordered {
            let next = elapsed + chunk.durationMs
            if mediaTimeMs <= next || chunk.id == ordered.last?.id {
                let duration = max(1, chunk.durationMs)
                let fraction = min(1, max(0, Double(mediaTimeMs - elapsed) / Double(duration)))
                let range = chunk.sourceRange
                let width = max(0, range.utf8End - range.utf8Start)
                let offset = Int((Double(width) * fraction).rounded())
                return SourceLocator(
                    documentId: range.documentId,
                    spineItemId: range.spineItemId,
                    segmentId: range.segmentId,
                    utf8Start: range.utf8Start + offset,
                    utf8End: range.utf8Start + offset
                )
            }
            elapsed = next
        }
        return nil
    }
}

public enum PreparationJobPolicy: String, Codable, Equatable, Sendable {
    case explicit
    case demandWindow = "demand_window"
    case whileCharging = "while_charging"
}

public enum AutomaticAudioPreparationPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case whileCharging = "while_charging"

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .whileCharging: "While Charging"
        }
    }
}

public struct AudioPreparationJob: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var manifestId: String
    public var policy: PreparationJobPolicy
    public var requestedAt: Date
    /// A user-controlled queue position within the job's policy tier. Older
    /// persisted jobs decode this as nil and retain their requested-at order.
    public var userPriority: Int?
    /// A bounded render horizon for demand work such as the two-chunk opening
    /// buffer. Nil means the job may continue through the complete plan.
    public var maximumChunkCount: Int?
    public var nextChunkIndex: Int
    public var isCancelled: Bool
    public var lastFailureCode: String?

    public init(
        schemaVersion: String = "audio-preparation-job.v1",
        id: String,
        itemId: String,
        manifestId: String,
        policy: PreparationJobPolicy,
        requestedAt: Date = Date(),
        userPriority: Int? = nil,
        maximumChunkCount: Int? = nil,
        nextChunkIndex: Int = 0,
        isCancelled: Bool = false,
        lastFailureCode: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.itemId = itemId
        self.manifestId = manifestId
        self.policy = policy
        self.requestedAt = requestedAt
        self.userPriority = userPriority.map { max(0, $0) }
        self.maximumChunkCount = maximumChunkCount.map { max(1, $0) }
        self.nextChunkIndex = max(0, nextChunkIndex)
        self.isCancelled = isCancelled
        self.lastFailureCode = lastFailureCode
    }
}

extension PreparedAudioManifest {
    /// Every planned chunk is committed but nothing is assembled into playable narration, for
    /// example after the fallback detached the narration it had (#278). Preparation must assemble
    /// it, because assembly otherwise runs only right after the last chunk is committed.
    public var isCompleteButUnassembled: Bool {
        state != .readyOffline && plannedChunkCount > 0
            && Set(chunks.map(\.index)).count >= plannedChunkCount
    }
}
