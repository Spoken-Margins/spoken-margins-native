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

    func value(at url: URL, compute: () throws -> String) rethrows -> String {
        // Only installed bundle resources are immutable for this process.
        // Imported/test assets must be rehashed, including same-size edits.
        let root = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root) else { return try compute() }
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
    static let modelRevision = "supertonic-3-int8"
    static let normalizationVersion = "speech-normalizer.v3"
    static let chunkingVersion = "rendered-speech-chunker.v2"

    static func make(
        assets: SupertonicAssetLocation,
        voice: SupertonicVoiceID,
        language: String = "en",
        synthesisSteps: Int = 8,
        speed: Float = 1,
        fileManager: FileManager = .default
    ) throws -> TTSRenderSignature {
        let assetHash = try bundledHashes.value(at: assets.onnxDirectoryURL) {
            try treeHash(at: assets.onnxDirectoryURL, fileManager: fileManager)
        }
        let voiceHash = try fileHash(at: assets.voiceStyleURL(for: voice), fileManager: fileManager)
        let parameters = "language=\(language)\u{1f}steps=\(synthesisSteps)\u{1f}synthesisSpeed=\(speed)"
        let parametersHash = sha256(Data(parameters.utf8))
        let canonical = [
            modelRevision,
            assetHash,
            voiceHash,
            parametersHash,
            normalizationVersion,
            chunkingVersion,
            "prepared-audio-manifest.v1"
        ].joined(separator: "\u{1f}")
        return TTSRenderSignature(
            engine: "supertonic",
            modelRevision: modelRevision,
            assetManifestHash: assetHash,
            voiceStyleHash: voiceHash,
            synthesisParametersHash: parametersHash,
            normalizationVersion: normalizationVersion,
            chunkingVersion: chunkingVersion,
            digest: sha256(Data(canonical.utf8))
        )
    }

    private static func treeHash(at directory: URL, fileManager: FileManager) throws -> String {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var digest = SHA256()
        for url in urls {
            digest.update(data: Data(url.lastPathComponent.utf8))
            digest.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let block = try handle.read(upToCount: 64 * 1_024), !block.isEmpty {
                digest.update(data: block)
            }
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileHash(at url: URL, fileManager: FileManager) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SupertonicNarrationError.missingAsset(url.lastPathComponent)
        }
        return sha256(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    func begin(
        itemId: String,
        sourceText: String,
        signature: TTSRenderSignature,
        plan: [PreparedChunkPlan],
        schedulesJob: Bool = true
    ) throws -> PreparedAudioManifest {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        let sourceId = "source-\(itemId)"
        if try repository.loadCanonicalSource(itemId: itemId) == nil {
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
           existing.plannedChunkCount == plan.count {
            // Eligibility/Stop is separate from artifact identity. Resume a
            // compatible partial representation without discarding its chunks.
            if existing.state == .notPrepared || existing.state == .stopped {
                existing.state = .preparing
                existing.failureCode = nil
                existing.updatedAt = Date()
                try repository.savePreparedAudioManifest(existing)
            } else if existing.state == .needsRepreparation {
                // Its narration was detached or a chunk failed its checksum (#278). Keep only the
                // chunks whose files are still intact, render the rest, and assemble again.
                existing.chunks = existing.chunks.filter(isIntact)
                existing.artifact = nil
                existing.state = .preparing
                existing.failureCode = nil
                existing.updatedAt = Date()
                try repository.savePreparedAudioManifest(existing)
            }
            return existing
        }
        for old in try repository.loadPreparedAudioManifests(itemId: itemId) where old.id != manifestId {
            var invalid = old
            invalid.state = .needsRepreparation
            invalid.updatedAt = Date()
            try repository.savePreparedAudioManifest(invalid)
        }
        let manifest = PreparedAudioManifest(
            id: manifestId,
            itemId: itemId,
            sourcePackageId: sourceId,
            signature: signature,
            state: .preparing,
            plannedChunkCount: plan.count
        )
        try repository.savePreparedAudioManifest(manifest)
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
              manifest.state == .preparing || manifest.state == .pausedForThermal else { return }
        let madeByManifestEngine = engine == nil || engine == manifest.signature.engine
        if let existing = manifest.chunks.first(where: { $0.index == plan.index }) {
            // Only the manifest's own engine replaces a stand-in; anything else keeps what's there.
            guard existing.engine != nil, madeByManifestEngine else { return }
            manifest.chunks.removeAll { $0.index == plan.index }
        }

        let directory = rootDirectory
            .appending(path: safePath(itemId), directoryHint: .isDirectory)
            .appending(path: signature.digest, directoryHint: .isDirectory)
            .appending(path: "chunks", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "%05d.wav", plan.index)
        let destination = directory.appending(path: name)
        let temporary = directory.appending(path: ".\(name).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: audioURL, to: temporary)
        let data = try Data(contentsOf: temporary, options: [.mappedIfSafe])
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporary, to: destination)
        let characterRange = plan.startOffset..<(plan.startOffset + plan.sourceLength)
        let locator = LegacySourceOffsetAdapter.locator(
            documentId: manifest.sourcePackageId,
            segmentId: "chunk-\(plan.index)",
            characterRange: characterRange,
            in: sourceText
        )
        manifest.chunks.append(PreparedAudioChunk(
            id: "\(manifestId)-chunk-\(plan.index)",
            index: plan.index,
            sourceRange: locator,
            relativePath: relativePath(destination),
            byteCount: Int64(data.count),
            checksumSHA256: SupertonicRenderIdentity.sha256(data),
            durationMs: durationMs,
            engine: madeByManifestEngine ? nil : engine
        ))
        manifest.chunks.sort { $0.index < $1.index }
        manifest.updatedAt = Date()
        try repository.savePreparedAudioManifest(manifest)
        if var job = try repository.loadAudioPreparationJobs().first(where: { $0.manifestId == manifestId }) {
            job.nextChunkIndex = manifest.chunks.count
            try repository.saveAudioPreparationJob(job)
        }
    }

    func complete(itemId: String, signature: TTSRenderSignature, prepared: PreparedTextAudio) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard var manifest = try repository.loadPreparedAudioManifest(id: manifestId),
              let rawURL = prepared.media.url,
              let url = URL(string: rawURL),
              url.isFileURL else { return }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        manifest.artifact = PreparedAudioArtifact(
            relativePath: relativePath(url),
            byteCount: Int64(data.count),
            checksumSHA256: SupertonicRenderIdentity.sha256(data),
            durationMs: prepared.media.durationMs ?? prepared.timeline.durationMs ?? 0
        )
        manifest.state = .readyOffline
        manifest.failureCode = nil
        manifest.updatedAt = Date()
        try repository.savePreparedAudioManifest(manifest)
        try repository.deleteAudioPreparationJob(id: "job-\(manifestId)")
    }

    func stop(itemId: String, signature: TTSRenderSignature) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard var manifest = try repository.loadPreparedAudioManifest(id: manifestId) else { return }
        manifest.state = .stopped
        manifest.updatedAt = Date()
        try repository.savePreparedAudioManifest(manifest)
        if var job = try repository.loadAudioPreparationJobs().first(where: { $0.manifestId == manifestId }) {
            job.isCancelled = true
            try repository.saveAudioPreparationJob(job)
        }
    }

    func retry(itemId: String, signature: TTSRenderSignature) throws {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard var manifest = try repository.loadPreparedAudioManifest(id: manifestId) else { return }
        guard manifest.state != .readyOffline else { return }
        manifest.state = .preparing
        manifest.failureCode = nil
        manifest.updatedAt = Date()
        try repository.savePreparedAudioManifest(manifest)
        var job = (try repository.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifestId })
            ?? AudioPreparationJob(id: "job-\(manifestId)", itemId: itemId, manifestId: manifestId, policy: .explicit)
        job.policy = .explicit
        job.isCancelled = false
        job.lastFailureCode = nil
        job.nextChunkIndex = manifest.chunks.count
        try repository.saveAudioPreparationJob(job)
    }

    private func isIntact(_ chunk: PreparedAudioChunk) -> Bool {
        let url = rootDirectory.appending(path: chunk.relativePath)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return Int64(data.count) == chunk.byteCount && SupertonicRenderIdentity.sha256(data) == chunk.checksumSHA256
    }

    func committedChunk(itemId: String, signature: TTSRenderSignature, plan: PreparedChunkPlan) throws -> PreparedChunkLookupResult? {
        let manifestId = "prepared-\(itemId)-\(signature.digest.prefix(16))"
        guard let manifest = try repository.loadPreparedAudioManifest(id: manifestId),
              manifest.signature == signature,
              manifest.state == .preparing || manifest.state == .pausedForThermal || manifest.state == .readyOffline,
              let chunk = manifest.chunks.first(where: { $0.index == plan.index }),
              // A stand-in (the iOS voice) isn't this manifest's audio: the player tries its engine
              // again rather than play the stand-in forever as if it were Supertonic (#363 audit).
              chunk.engine == nil else { return nil }
        let url = rootDirectory.appending(path: chunk.relativePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) == chunk.byteCount,
              SupertonicRenderIdentity.sha256(data) == chunk.checksumSHA256 else {
            var invalid = manifest
            invalid.state = .needsRepreparation
            invalid.failureCode = "chunk_checksum_mismatch"
            invalid.updatedAt = Date()
            try repository.savePreparedAudioManifest(invalid)
            return nil
        }
        return PreparedChunkLookupResult(audioURL: url, duration: Double(chunk.durationMs) / 1_000)
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
