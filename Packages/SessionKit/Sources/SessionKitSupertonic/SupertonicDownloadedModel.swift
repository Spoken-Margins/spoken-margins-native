import CryptoKit
import Foundation
import SessionKit

/// Supertonic's model is a download (#1820), so its files can arrive or leave while the app runs. Anything built over
/// them asks this, each time, for the renderer and for whether the model is there. Nothing about the files is decided
/// when the player is built: a download is heard at the listener's next play, and a Remove hands the next passage to
/// the backup voice, without rebuilding the player. The player's own rule decides when the voice may change, so it
/// never changes in the middle of a run (owner, 2026-10-15).
public final class SupertonicModelFollower<Renderer: AnyObject & Sendable>: @unchecked Sendable {
    private let locate: @Sendable () -> SupertonicAssetLocation?
    private let retire: @Sendable (Renderer) -> Void
    private let lock = NSLock()
    private var built: (location: SupertonicAssetLocation, renderer: Renderer)?

    /// `locate` finds the model on the phone now, or nil. `retire` receives a renderer whose files are gone or
    /// replaced, to unload it.
    public init(
        locate: @escaping @Sendable () -> SupertonicAssetLocation?,
        retire: @escaping @Sendable (Renderer) -> Void = { _ in }
    ) {
        self.locate = locate
        self.retire = retire
    }

    public var isModelPresent: Bool { locate() != nil }

    /// The renderer built for the files on the phone, if one has been built and they are still there.
    public var current: Renderer? { lock.withLock { built?.renderer } }

    /// "May Supertonic render now?": the model is on the phone and `condition` (the phone's heat, memory and power)
    /// allows it. Asked at every render, never fixed when the player is built.
    public func renderingAllowed(when condition: @escaping @Sendable () -> Bool) -> @Sendable () -> Bool {
        { [self] in isModelPresent && condition() }
    }

    /// The renderer for the model on the phone now: the one already built when the files are the same, otherwise a new
    /// one from `make`. Throws `missingAsset` when the model isn't there. A renderer whose files are gone or replaced
    /// is retired.
    public func renderer(make: (SupertonicAssetLocation) throws -> Renderer) throws -> Renderer {
        guard let location = locate() else {
            reset()
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        let existing = lock.withLock { built }
        if let existing, existing.location == location { return existing.renderer }
        let made = try make(location)
        let (kept, retired) = lock.withLock { () -> (Renderer, Renderer?) in
            // Another caller may have built one meanwhile; the first one for these files wins.
            if let current = built, current.location == location { return (current.renderer, made) }
            let old = built?.renderer
            built = (location, made)
            return (made, old)
        }
        if let retired { retire(retired) }
        return kept
    }

    /// Forgets the built renderer and returns it, retiring it unless `retiring` is false (the caller unloads it).
    @discardableResult
    public func reset(retiring: Bool = true) -> Renderer? {
        let old = lock.withLock { () -> Renderer? in
            defer { built = nil }
            return built?.renderer
        }
        if retiring, let old { retire(old) }
        return old
    }

    /// Retires the built renderer when its files are no longer the model on the phone, as after a Remove.
    public func retireIfReplaced() {
        let location = locate()
        let stale = lock.withLock { () -> Renderer? in
            guard let current = built, current.location != location else { return nil }
            built = nil
            return current.renderer
        }
        if let stale { retire(stale) }
    }
}

/// The identity Supertonic's saved audio is filed under (#336): the model's tree hash, the voice style's hash, the
/// synthesis parameters and the text pipeline's versions. Computed from the model files when they are on the phone,
/// or from the hashes pinned in the app's `asset-manifest.json` when they aren't, so audio saved before a download,
/// or before a Remove, still plays (#1820). Both give the same identity for the same bytes.
public enum SupertonicRenderSignature {
    public static let modelRevision = "supertonic-3-int8"
    public static let normalizationVersion = "speech-normalizer.v3"
    public static let chunkingVersion = NarrationChunkPlanner.version

    public static func make(
        onnxTreeHash: String,
        voiceStyleHash: String,
        language: String = "en",
        synthesisSteps: Int = 8,
        speed: Float = 1
    ) -> TTSRenderSignature {
        let parameters = "language=\(language)\u{1f}steps=\(synthesisSteps)\u{1f}synthesisSpeed=\(speed)"
        let parametersHash = SupertonicModelHashes.sha256(Data(parameters.utf8))
        let canonical = [
            modelRevision,
            onnxTreeHash,
            voiceStyleHash,
            parametersHash,
            normalizationVersion,
            chunkingVersion,
            "prepared-audio-manifest.v2"
        ].joined(separator: "\u{1f}")
        return TTSRenderSignature(
            engine: "supertonic",
            modelRevision: modelRevision,
            assetManifestHash: onnxTreeHash,
            voiceStyleHash: voiceStyleHash,
            synthesisParametersHash: parametersHash,
            normalizationVersion: normalizationVersion,
            chunkingVersion: chunkingVersion,
            digest: SupertonicModelHashes.sha256(Data(canonical.utf8))
        )
    }

    /// From the hashes pinned in `asset-manifest.json`; nil when it doesn't pin the tree hash or this voice.
    public static func make(pinnedBy manifest: SupertonicModelHashes, voice: SupertonicVoiceID) -> TTSRenderSignature? {
        guard let tree = manifest.onnxTreeHash, let style = manifest.voiceStyleHash(for: voice) else { return nil }
        return make(onnxTreeHash: tree, voiceStyleHash: style)
    }
}

/// The model's hashes as `asset-manifest.json` pins them, and how they are computed from the files.
public struct SupertonicModelHashes: Decodable, Equatable, Sendable {
    public struct File: Decodable, Equatable, Sendable {
        public let path: String
        public let sha256: String
    }

    /// `onnxTreeHash(at:)` of the `onnx/` folder the catalog downloads (and the app used to bundle).
    public let onnxTreeHash: String?
    public let files: [File]

    public static func load(from url: URL) throws -> SupertonicModelHashes {
        try JSONDecoder().decode(SupertonicModelHashes.self, from: Data(contentsOf: url))
    }

    public func sha256(ofFile path: String) -> String? {
        files.first { $0.path == path }?.sha256
    }

    public func voiceStyleHash(for voice: SupertonicVoiceID) -> String? {
        sha256(ofFile: "voice_styles/\(voice.rawValue).json")
    }

    /// Each regular, visible file of the folder in name order: its name, a zero byte, its bytes, a zero byte.
    public static func onnxTreeHash(at directory: URL, fileManager: FileManager = .default) throws -> String {
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

    public static func fileHash(at url: URL, fileManager: FileManager = .default) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SupertonicNarrationError.missingAsset(url.lastPathComponent)
        }
        return sha256(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
