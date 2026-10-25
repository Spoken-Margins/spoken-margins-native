import AVFoundation
import CryptoKit
import Foundation
import SessionKit
import SessionKitSupertonic

struct PreparedChunkPlan: Equatable, Sendable {
    var index: Int
    var startOffset: Int
    var sourceLength: Int
    var text: String

    /// Background preparation's plan for an article: the article plan the player's lookups use too
    /// (#312). Production and the tests both call this, so they can't drift apart.
    static func articlePlan(_ articleText: String) -> [PreparedChunkPlan] {
        NarrationChunkPlanner.articlePlan(articleText).chunks.map {
            PreparedChunkPlan(index: $0.index, startOffset: $0.startOffset, sourceLength: $0.sourceLength, text: $0.text)
        }
    }
}

/// Single-entry cache: bounds retained text/plans while reusing a document
/// across successive chunk jobs. Changed source always requires a new plan.
final class PreparedChunkPlanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var source: String?
    private var plan: [PreparedChunkPlan] = []

    func removeAll() {
        lock.lock()
        source = nil
        plan.removeAll()
        lock.unlock()
    }

    func value(for text: String, build: () -> [PreparedChunkPlan]) -> [PreparedChunkPlan] {
        lock.lock()
        if source == text {
            let result = plan
            lock.unlock()
            return result
        }
        lock.unlock()
        let result = build()
        lock.lock()
        source = text
        plan = result
        lock.unlock()
        return result
    }
}

private final class BundledModelHashCache: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes: [URL: String] = [:]

    /// Folders whose files never change while the app runs: the app bundle, and the downloaded voices (#1820). The
    /// voice installer verifies each file's hash and moves a whole version folder into place; a new version gets a
    /// new folder and a removed one is deleted, so a folder's bytes never change in place. Without this, every play
    /// and preparation pass would hash Supertonic's 145 MB again now that it is a download.
    private static let immutableRoots: [String] = {
        var roots = [Bundle.main.bundleURL]
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            roots.append(VoiceCatalogCoordinator.voicesRoot(supportDirectory: support))
        }
        return roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
    }()

    func value(at url: URL, compute: () throws -> String) rethrows -> String {
        // Imported and test assets elsewhere must be rehashed, including same-size edits.
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.immutableRoots.contains(where: { path.hasPrefix($0) }) else { return try compute() }
        lock.lock()
        let cached = hashes[url]
        lock.unlock()
        if let cached { return cached }
        let result = try compute()
        lock.lock()
        hashes[url] = result
        lock.unlock()
        return result
    }
}

enum SupertonicRenderIdentity {
    private static let bundledHashes = BundledModelHashCache()
    /// The model's hashes as the app's `asset-manifest.json` pins them, read once.
    private static let pinned: SupertonicModelHashes? = Bundle.main
        .url(forResource: "asset-manifest", withExtension: "json", subdirectory: "Supertonic")
        .flatMap { try? SupertonicModelHashes.load(from: $0) }

    static func make(
        assets: SupertonicAssetLocation,
        voice: SupertonicVoiceID,
        fileManager: FileManager = .default
    ) throws -> TTSRenderSignature {
        let assetHash = try bundledHashes.value(at: assets.onnxDirectoryURL) {
            try SupertonicModelHashes.onnxTreeHash(at: assets.onnxDirectoryURL, fileManager: fileManager)
        }
        let voiceHash = try SupertonicModelHashes.fileHash(at: assets.voiceStyleURL(for: voice), fileManager: fileManager)
        return SupertonicRenderSignature.make(onnxTreeHash: assetHash, voiceStyleHash: voiceHash)
    }

    /// The identity of `voice`'s saved audio whether or not the model is on the phone (#1820): from its files when
    /// they are there, otherwise from the pinned hashes, which name the same bytes. Throws only when neither is there.
    static func current(voice: SupertonicVoiceID, assets: SupertonicAssetLocation? = SupertonicAssetResolver.location()) throws -> TTSRenderSignature {
        if let assets { return try make(assets: assets, voice: voice) }
        guard let pinned, let signature = SupertonicRenderSignature.make(pinnedBy: pinned, voice: voice) else {
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        return signature
    }

    static func sha256(_ data: Data) -> String {
        SupertonicModelHashes.sha256(data)
    }
}

actor PreparedAudioCoordinator {
    private let repository: any SessionRepository
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(repository: any SessionRepository, rootDirectory: URL, fileManager: FileManager = .default) {
        self.repository = repository
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// Every manifest write goes through here so the playback screen's frontier poll can wake (#2652).
    private func saveManifest(_ manifest: PreparedAudioManifest) throws {
        try repository.savePreparedAudioManifest(manifest)
        PreparedAudioChangeSignal.shared.bump()
    }

    func begin(
        itemId: String,
        sourceText: String,
        signature: TTSRenderSignature,
        plan: [PreparedChunkPlan],
        schedulesJob: Bool = true
    ) throws -> PreparedAudioManifest {
        try PreparedAudioEnqueue.withValidatedSource(itemId: itemId, sourceText: sourceText, repository: repository) {
            try beginValidated(itemId: itemId, sourceText: sourceText, signature: signature, plan: plan, schedulesJob: schedulesJob)
        }
    }

    private func beginValidated(
        itemId: String, sourceText: String, signature: TTSRenderSignature,
        plan: [PreparedChunkPlan], schedulesJob: Bool
    ) throws -> PreparedAudioManifest {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        let sourceId = "source-\(itemId)"
        if try repository.loadCanonicalSource(itemId: itemId)?.segments.map(\.text).joined() != sourceText {
            let locator = SourceLocator(
                documentId: sourceId,
                segmentId: "segment-0001",
                utf8Start: 0,
                utf8End: sourceText.utf8.count
            )
            try repository.saveCanonicalSource(CanonicalSourcePackage(
                id: sourceId,
                itemId: itemId,
                sourceDocumentId: sourceId,
                format: .plainText,
                title: itemId,
                navigation: [],
                segments: [SpeakableSegment(id: locator.segmentId, text: sourceText, locator: locator)]
            ))
        }
        if var existing = try repository.loadPreparedAudioManifest(id: manifestId),
           existing.signature == signature,
           existing.plannedChunkCount == plan.count,
           Self.isMade(from: sourceText, existing) {
            // Eligibility/Stop is separate from artifact identity. Resume a
            // compatible partial representation without discarding its chunks.
            if existing.state == .notPrepared || existing.state == .stopped {
                existing.state = .preparing
                existing.failureCode = nil
                existing.updatedAt = Date()
                try saveManifest(existing)
            } else if existing.state == .needsRepreparation {
                // Its narration was detached or a chunk failed its checksum (#278). Keep only the
                // chunks whose files are still intact, render the rest, and assemble again.
                existing.chunks = existing.chunks.filter(isIntact)
                existing.artifact = nil
                existing.state = .preparing
                existing.failureCode = nil
                existing.updatedAt = Date()
                try saveManifest(existing)
            }
            return existing
        }
        for old in try repository.loadPreparedAudioManifests(itemId: itemId) where old.id != manifestId {
            var invalid = old
            invalid.state = .needsRepreparation
            invalid.updatedAt = Date()
            try saveManifest(invalid)
        }
        let manifest = PreparedAudioManifest(
            id: manifestId,
            itemId: itemId,
            sourcePackageId: sourceId,
            signature: signature,
            state: .preparing,
            plannedChunkCount: plan.count,
            articleIdentity: NarrationChunkPlanner.identity(ofArticle: sourceText)
        )
        try saveManifest(manifest)
        if schedulesJob {
            try repository.saveAudioPreparationJob(AudioPreparationJob(
                id: "job-\(manifestId)",
                itemId: itemId,
                manifestId: manifestId,
                policy: .demandWindow
            ))
        }
        return manifest
    }

    func commit(
        itemId: String,
        signature: TTSRenderSignature,
        plan: PreparedChunkPlan,
        sourceText: String,
        audioURL: URL,
        durationMs: Int,
        engine: String? = nil
    ) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard var manifest = try repository.loadPreparedAudioManifest(id: manifestId),
              manifest.signature == signature,
              manifest.state == .preparing || manifest.state == .pausedForThermal,
              Self.isMade(from: sourceText, manifest) else { return }
        let madeByManifestEngine = engine == nil || engine == manifest.signature.engine
        if let existing = manifest.chunks.first(where: { $0.index == plan.index }) {
            // Saved for the same words: keep it, unless it's a stand-in and this is the manifest's
            // own engine (#311). Saved for another stretch of the text: replace it (#312).
            if existing.sourceRange == Self.sourceRange(of: plan, manifest: manifest, sourceText: sourceText),
               existing.engine == nil || !madeByManifestEngine { return }
            manifest.chunks.removeAll { $0.index == plan.index }
        }

        let directory = rootDirectory
            .appending(path: safePath(itemId), directoryHint: .isDirectory)
            .appending(path: signature.digest, directoryHint: .isDirectory)
            .appending(path: "chunks", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let articleIdentity = NarrationChunkPlanner.identity(ofArticle: sourceText)
        // Keep the legacy directory layout; source-specific names spare files still used by another item.
        let name = articleIdentity + "-" + String(format: "%05d.wav", plan.index)
        let destination = directory.appending(path: name)
        let temporary = directory.appending(path: ".\(name).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: audioURL, to: temporary)
        let data = try Data(contentsOf: temporary, options: [.mappedIfSafe])
        manifest.chunks.append(PreparedAudioChunk(
            id: "\(manifestId)-\(articleIdentity)-chunk-\(plan.index)",
            index: plan.index,
            sourceRange: Self.sourceRange(of: plan, manifest: manifest, sourceText: sourceText),
            relativePath: relativePath(destination),
            byteCount: Int64(data.count),
            checksumSHA256: SupertonicRenderIdentity.sha256(data),
            durationMs: durationMs,
            engine: madeByManifestEngine ? nil : engine
        ))
        manifest.chunks.sort { $0.index < $1.index }
        manifest.updatedAt = Date()
        _ = try saveUnlessRetired(manifest, stillCurrent: { (try? PreparedAudioEnqueue.preparedText(item: $0, repository: repository)) == sourceText }, commitFile: {
            // Copy/hash outside the transaction; publish the file only while its preparation is current.
            if self.fileManager.fileExists(atPath: destination.path) { try self.fileManager.removeItem(at: destination) }
            try self.fileManager.moveItem(at: temporary, to: destination)
        })
    }

    /// True when a Stop, a failure or a new voice has retired this manifest, so audio finished for it
    /// must not be attached or marked ready (#2134). A manifest that does not exist is not refused.
    func refusesCompletion(itemId: String, signature: TTSRenderSignature) throws -> Bool {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard let manifest = try repository.loadPreparedAudioManifest(id: manifestId) else { return false }
        return !PreparedAudioEnqueue.mayComplete(manifest.state)
    }

    /// False when the manifest is gone or was retired by a re-import meanwhile (#344 audit).
    @discardableResult
    func complete(itemId: String, signature: TTSRenderSignature, prepared: PreparedTextAudio) throws -> Bool {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard try repository.loadPreparedAudioManifest(id: manifestId) != nil,
              let rawURL = prepared.media.url,
              let url = URL(string: rawURL),
              url.isFileURL else { return false }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // Loaded after the hash, which a re-import can overtake (#344 audit).
        guard var manifest = try repository.loadPreparedAudioManifest(id: manifestId),
              PreparedAudioEnqueue.mayComplete(manifest.state) else { return false }
        manifest.artifact = PreparedAudioArtifact(
            relativePath: relativePath(url),
            byteCount: Int64(data.count),
            checksumSHA256: SupertonicRenderIdentity.sha256(data),
            durationMs: prepared.media.durationMs ?? prepared.timeline.durationMs ?? 0
        )
        manifest.state = .readyOffline
        manifest.failureCode = nil
        manifest.updatedAt = Date()
        guard try saveUnlessRetired(manifest, stillCurrent: { Self.isMade(from: (try? PreparedAudioEnqueue.preparedText(item: $0, repository: repository)) ?? "", manifest) },
                                    stillAllowed: { PreparedAudioEnqueue.mayComplete($0.state) }) else { return false }
        return true
    }

    /// Saves progress/completion and its job atomically with the retirement check.
    /// File copying and hashing happen before entering this short transaction.
    private func saveUnlessRetired(_ manifest: PreparedAudioManifest, stillCurrent: (Item) -> Bool, stillAllowed: (PreparedAudioManifest) -> Bool = { _ in true }, commitFile: (() throws -> Void)? = nil) throws -> Bool {
        try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: repository) { saved, item in
            guard stillCurrent(item), stillAllowed(saved) else { return false }
            try commitFile?()
            try saveManifest(manifest)
            if manifest.state == .readyOffline {
                try repository.deleteAudioPreparationJob(id: "job-\(manifest.id)")
            } else if var job = try repository.loadAudioPreparationJobs().first(where: { $0.manifestId == manifest.id }) {
                job.nextChunkIndex = manifest.chunks.count
                try repository.saveAudioPreparationJob(job)
            }
            return true
        } ?? false
    }

    func stop(itemId: String, signature: TTSRenderSignature) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard let candidate = try repository.loadPreparedAudioManifest(id: manifestId) else { return }
        _ = try PreparedAudioEnqueue.withCurrentManifest(candidate, repository: repository) { current, _ in
            var manifest = current
            manifest.state = .stopped
            manifest.updatedAt = Date()
            try saveManifest(manifest)
            if var job = try repository.loadAudioPreparationJobs().first(where: { $0.manifestId == manifestId }) {
                job.isCancelled = true
                try repository.saveAudioPreparationJob(job)
            }
        }
    }

    func retry(itemId: String, signature: TTSRenderSignature) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard let candidate = try repository.loadPreparedAudioManifest(id: manifestId) else { return }
        _ = try PreparedAudioEnqueue.withCurrentManifest(candidate, repository: repository) { current, _ in
            guard current.state != .readyOffline else { return }
            var manifest = current
            manifest.state = .preparing
            manifest.failureCode = nil
            manifest.updatedAt = Date()
            try saveManifest(manifest)
            var job = (try repository.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifestId })
                ?? AudioPreparationJob(id: "job-\(manifestId)", itemId: itemId, manifestId: manifestId, policy: .explicit)
            job.policy = .explicit
            job.isCancelled = false
            job.lastFailureCode = nil
            job.nextChunkIndex = manifest.chunks.count
            try repository.saveAudioPreparationJob(job)
        }
    }

    /// Applies a preparation-gate decision (#64) to the manifest as it is saved now, not to the
    /// pass's earlier copy, so a chunk committed by playback, a Stop or a completion while the pass
    /// was setting up is kept (Codex audit on bae0dc4). Returns the current manifest, nil if it's
    /// gone, and whether its state changed.
    func applyGate(_ decision: PreparationChunkDecision, manifestId: String) throws -> (manifest: PreparedAudioManifest?, changed: Bool) {
        guard let candidate = try repository.loadPreparedAudioManifest(id: manifestId) else { return (nil, false) }
        return try PreparedAudioEnqueue.withCurrentManifest(candidate, repository: repository) { current, _ in
            var manifest = current
            guard let state = PreparationChunkGate.manifestState(after: decision, current: manifest.state) else { return (manifest, false) }
            manifest.state = state
            manifest.updatedAt = Date()
            try saveManifest(manifest)
            return (manifest, true)
        } ?? (nil, false)
    }

    /// Forgets committed chunks whose files are gone or the wrong size, so they're rendered again
    /// rather than counted as done (#645). Without this, a chunk evicted or lost after it was
    /// committed sent every retry back into an assembly that could only fail on the missing file.
    /// Only an unassembled manifest is changed; a finished one's chunks are meant to be evicted.
    /// Returns the manifest as saved now, nil if it's gone.
    func droppingMissingChunks(manifestId: String) throws -> PreparedAudioManifest? {
        guard let candidate = try repository.loadPreparedAudioManifest(id: manifestId) else { return nil }
        return try PreparedAudioEnqueue.withCurrentManifest(candidate, repository: repository) { current, _ in
            var manifest = current
            guard manifest.artifact == nil, manifest.state == .preparing || manifest.state == .pausedForThermal else { return manifest }
            let present = manifest.chunks.filter(hasFile)
            guard present.count < manifest.chunks.count else { return manifest }
            manifest.chunks = present
            manifest.updatedAt = Date()
            try saveManifest(manifest)
            if var job = try repository.loadAudioPreparationJobs().first(where: { $0.manifestId == manifestId }) {
                job.nextChunkIndex = manifest.chunks.count
                try repository.saveAudioPreparationJob(job)
            }
            return manifest
        }
    }

    /// The ledger paths of a manifest's committed chunks, which its next render and its assembly
    /// pin so their own reservations can't evict them (#645). Chunk rows are committed to the
    /// ledger under `PreparedAudio/`, the coordinator's root.
    static func ledgerPaths(ofChunksIn manifest: PreparedAudioManifest) -> Set<String> {
        Set(manifest.chunks.map(ledgerPath(of:)))
    }

    /// The ledger row for a committed chunk. It is built here, from the same path the pins use,
    /// so a pin always names the row its reservation must not evict (#645).
    static func ledgerAsset(for chunk: PreparedAudioChunk, itemId: String) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: chunk.id,
            itemId: itemId,
            category: .preparedChunk,
            relativePath: ledgerPath(of: chunk),
            byteCount: chunk.byteCount,
            checksumSHA256: chunk.checksumSHA256,
            isReproducible: true
        )
    }

    private static func ledgerPath(of chunk: PreparedAudioChunk) -> String {
        "PreparedAudio/\(chunk.relativePath)"
    }

    /// A size check, not a checksum: this runs on every preparation pass.
    private func hasFile(_ chunk: PreparedAudioChunk) -> Bool {
        let url = rootDirectory.appending(path: chunk.relativePath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return false }
        return Int64(values.fileSize ?? -1) == chunk.byteCount
    }

    private func isIntact(_ chunk: PreparedAudioChunk) -> Bool {
        let url = rootDirectory.appending(path: chunk.relativePath)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return Int64(data.count) == chunk.byteCount && SupertonicRenderIdentity.sha256(data) == chunk.checksumSHA256
    }

    static let standInRetried = "stand_in_retried"

    /// The chunks background preparation needn't render: those saved for the same stretch of this
    /// text (#312). A listener's explicit request renders a stand-in chunk with Supertonic once more;
    /// if the stand-in comes back, the job records that and doesn't try again (#363 audit).
    static func completedIndexes(
        _ manifest: PreparedAudioManifest, plan: [PreparedChunkPlan], sourceText: String,
        retryingStandInsFor job: AudioPreparationJob
    ) -> Set<Int> {
        let retries = job.policy == .explicit && job.lastFailureCode != standInRetried
        return Set(matchingChunks(in: manifest, plan: plan, sourceText: sourceText).filter { !retries || $0.engine == nil }.map(\.index))
    }

    /// Whether any committed chunk is a stand-in. Such a manifest isn't assembled into the item's
    /// audio, so a wrongly flagged chunk can be rendered again on a later play (#311, #363 audit).
    static func hasStandIns(_ manifest: PreparedAudioManifest) -> Bool {
        manifest.chunks.contains { $0.engine != nil }
    }

    /// The committed audio for `plan`, only when it was saved for the same stretch of `sourceText`.
    /// Matching the index alone could hand back another stretch's audio if the plan shifted (#312).
    /// `engine` nil asks for the manifest's own engine's audio; another engine (the bundled Kitten voice) asks for
    /// that engine's stand-in, which the player plays while that voice holds narration (#1680).
    func committedChunk(
        itemId: String, signature: TTSRenderSignature, plan: PreparedChunkPlan, sourceText: String, engine: String? = nil
    ) throws -> PreparedChunkLookupResult? {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard let manifest = try repository.loadPreparedAudioManifest(id: manifestId),
              manifest.signature == signature,
              manifest.state == .preparing || manifest.state == .pausedForThermal || manifest.state == .readyOffline,
              Self.isMade(from: sourceText, manifest),
              let chunk = manifest.chunks.first(where: { $0.index == plan.index }),
              chunk.sourceRange == Self.sourceRange(of: plan, manifest: manifest, sourceText: sourceText),
              // A stand-in isn't this manifest's audio: asked for the manifest's own, the player tries its engine
              // again rather than play the stand-in forever as if it were Supertonic (#363 audit). A stand-in is
              // found only when its own engine is asked for (#1680).
              chunk.engine == (engine == manifest.signature.engine ? nil : engine) else { return nil }
        let url = rootDirectory.appending(path: chunk.relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) == chunk.byteCount,
              SupertonicRenderIdentity.sha256(data) == chunk.checksumSHA256 else {
            var invalid = manifest
            invalid.state = .needsRepreparation
            invalid.failureCode = "chunk_checksum_mismatch"
            invalid.updatedAt = Date()
            try saveManifest(invalid)
            return nil
        }
        return PreparedChunkLookupResult(audioURL: url, duration: Double(chunk.durationMs) / 1_000)
    }

    /// The committed chunks saved for the same stretch of `sourceText` as `plan` plans. Background
    /// preparation and assembly count only these, as the player's lookups do (#312).
    static func matchingChunks(
        in manifest: PreparedAudioManifest, plan: [PreparedChunkPlan], sourceText: String
    ) -> [PreparedAudioChunk] {
        guard isMade(from: sourceText, manifest) else { return [] }
        let planned = Dictionary(plan.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        return manifest.chunks.filter { chunk in
            planned[chunk.index].map { chunk.sourceRange == sourceRange(of: $0, manifest: manifest, sourceText: sourceText) } ?? false
        }
    }

    /// What assembly stitches together: each planned chunk's matching committed audio, with the
    /// article plan's boundary. Only chunks saved for the same stretch of this text count (#312);
    /// a missing or stale one throws, and is rendered again first.
    static func assemblyChunks(
        plan: [PreparedChunkPlan], manifest: PreparedAudioManifest, sourceText: String, preparedRoot: URL
    ) throws -> [SupertonicPreparedChunk] {
        let byIndex = Dictionary(uniqueKeysWithValues: matchingChunks(in: manifest, plan: plan, sourceText: sourceText).map { ($0.index, $0) })
        let articleChunks = NarrationChunkPlanner.articlePlan(sourceText).chunks
        return try plan.map { entry in
            guard let committed = byIndex[entry.index], articleChunks.indices.contains(entry.index) else {
                throw SessionKitError.persistenceFailed("prepared_chunk_missing")
            }
            return SupertonicPreparedChunk(
                startOffset: entry.startOffset, sourceLength: entry.sourceLength, text: entry.text,
                boundary: articleChunks[entry.index].boundary,
                audioURL: preparedRoot.appending(path: committed.relativePath)
            )
        }
    }

    /// Whether the manifest's audio was made from this article text. Saved ranges hold offsets, not
    /// words, so an edit that keeps the offsets would otherwise match old audio (#375 audit).
    /// Manifests from before #312 carry no identity and keep the range check alone.
    static func isMade(from sourceText: String, _ manifest: PreparedAudioManifest) -> Bool {
        manifest.articleIdentity.map { $0 == NarrationChunkPlanner.identity(ofArticle: sourceText) } ?? true
    }

    /// Whether every planned chunk has matching committed audio, as a demand window needs before
    /// its job is done. A chunk saved for other words doesn't count (#375 audit).
    static func isPrepared(_ plan: [PreparedChunkPlan], in manifest: PreparedAudioManifest, sourceText: String) -> Bool {
        let matching = Set(matchingChunks(in: manifest, plan: plan, sourceText: sourceText).map(\.index))
        return plan.allSatisfy { matching.contains($0.index) }
    }

    private static func sourceRange(of plan: PreparedChunkPlan, manifest: PreparedAudioManifest, sourceText: String) -> SourceLocator {
        LegacySourceOffsetAdapter.locator(
            documentId: manifest.sourcePackageId,
            segmentId: "chunk-\(plan.index)",
            characterRange: plan.startOffset..<(plan.startOffset + plan.sourceLength),
            in: sourceText
        )
    }

    private func relativePath(_ url: URL) -> String {
        let root = rootDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func safePath(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(80))
    }
}
