#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Phonon 31M (English), the downloadable Neural Engine voice from Gradium (#2704). The model is a Core ML bundle
// from Gradium's xn-ptts v0.4.2 release, installed by the catalog into the voice's own folder. What can be decided
// without the Neural Engine lives here, so the host tests cover it: which files make a usable bundle, which voices
// the catalog lists and the one read by default, the identity its saved audio is filed under, and the one-time
// compile after download. The app's `PhononTTS` adapter does the rest.

public enum PhononVoice {
    /// The catalog id, `Contracts/voice-models/sources.json`.
    public static let catalogId = "phonon-31m-en"
    /// What `SupertonicNarrationResult.engine` and `TTSRenderSignature.engine` say for Phonon's audio. The two must
    /// match, or the prepared-audio coordinator files Phonon's chunks as stand-ins.
    public static let engine = catalogId
    /// Every sample is mono Float32 at this rate (`Phonon.sampleRate`).
    public static let sampleRate = 24_000
    /// Text normalisation Phonon applies before tokenising. English only: the 31M model is English.
    public static let language = "en"

    /// The catalogue voices the catalog downloads, in the bundle's sorted order. The 12 character voices
    /// ("Grub the Ogre" and the like) and the bundle's unnamed `default` copy are left out (#2704).
    public static let voiceNames: [String] = [
        "Alfie", "Bryony", "Delia", "Easton", "Edwin", "Elodie-Rose", "Everly", "Freya", "Hadley", "Harper", "Hugh",
        "Imogen", "Juniper", "Lottie", "Maeve", "Micah", "Miles", "Pippa", "Preston", "Russell", "Spencer", "Teddy",
        "Toby", "Trevor", "Zoey",
    ]

    /// The voice read until the owner picks one by ear (the issue's owner check). Alfie is the one Gradium's own
    /// `Phonon.load` starts on (the first in sorted order), so the first paragraph needs no voice switch.
    public static let defaultVoiceName = "Alfie"

    public static func isKnownVoice(_ name: String) -> Bool { voiceNames.contains(name) }
}

public enum PhononModelError: Error, Equatable, LocalizedError {
    case missingAsset(String)
    case unknownVoice(String)
    case notCompiled(String)
    case emptyText
    case emptyAudio
    case unsafeAudio(String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let name): "Phonon's model is missing \(name)."
        case .unknownVoice(let name): "Phonon has no voice called \(name)."
        case .notCompiled(let name): "Phonon's \(name) wasn't compiled for this device."
        case .emptyText: "The text to speak is empty."
        case .emptyAudio: "Phonon generated no playable audio."
        case .unsafeAudio(let reason): "Phonon generated invalid audio: \(reason)."
        }
    }
}

/// An installed Phonon bundle: the catalog's version folder for `phonon-31m-en`.
public struct PhononModelLocation: Equatable, Sendable {
    /// The three Core ML programs; `Phonon.load` compiles each into a `.mlmodelc` beside it.
    public static let modelPackages = ["flow-c414-t1.mlpackage", "flow-c414-t48.mlpackage", "mimi-c266.mlpackage"]
    public static let requiredFiles = ["bundle.json", "host.safetensors", "tokenizer.json"]

    public let rootURL: URL

    public init(rootURL: URL) { self.rootURL = rootURL }

    public func voiceURL(_ name: String) -> URL { rootURL.appending(path: "voices/\(name).safetensors") }

    /// Throws for the first file or package that isn't there, so a broken install fails at load, not mid-paragraph.
    public func validate(voice: String = PhononVoice.defaultVoiceName, fileManager: FileManager = .default) throws {
        for name in Self.requiredFiles + Self.modelPackages
        where !fileManager.fileExists(atPath: rootURL.appending(path: name).path) {
            throw PhononModelError.missingAsset(name)
        }
        guard fileManager.fileExists(atPath: voiceURL(voice).path) else { throw PhononModelError.unknownVoice(voice) }
    }

    /// The packages with no compiled copy beside them (what `Phonon.needsCompiling` checks).
    public func uncompiledPackages(fileManager: FileManager = .default) -> [String] {
        Self.modelPackages.filter { package in
            !fileManager.fileExists(atPath: compiledURL(of: package).path)
        }
    }

    public func compiledURL(of package: String) -> URL {
        rootURL.appending(path: String(package.dropLast(".mlpackage".count)) + ".mlmodelc")
    }
}

/// The identity Phonon's saved audio is filed under (#64, #336): the bundle's files as the catalog pins them, the
/// voice's own file, the synthesis settings and the text pipeline's versions. Built from the catalog entry, so the
/// same audio keeps its identity before a download, after it, and after a Remove; nothing is hashed at play time.
public enum PhononRenderSignature {
    public static let normalizationVersion = "ptts-normalize-en.v0.4.2"
    public static let chunkingVersion = NarrationChunkPlanner.version
    /// The bundle's own sampling settings (`bundle.json`: temperature 0.3, eos threshold 4.0), unchanged by us.
    public static let synthesisParameters = "language=en\u{1f}computeUnit=neuralEngine\u{1f}temperature=bundle"

    /// SHA-256 over the model files' catalog hashes (path and hash, sorted by path). Voices and licence texts are
    /// left out: a voice is its own `voiceStyleHash`, and a licence file never changes the audio.
    public static func assetManifestHash(of entry: VoiceModelEntry) -> String {
        let lines = entry.files
            .filter { !$0.path.hasPrefix("voices/") && !$0.path.hasPrefix("licenses/") }
            .sorted { $0.path < $1.path }
            .map { "\($0.path)\u{1f}\($0.sha256)" }
        return sha256(lines.joined(separator: "\n"))
    }

    /// Nil when `entry` isn't Phonon's or doesn't list `voice`.
    public static func make(entry: VoiceModelEntry, voice: String) -> TTSRenderSignature? {
        guard entry.id == PhononVoice.catalogId,
              let voiceFile = entry.files.first(where: { $0.path == "voices/\(voice).safetensors" }) else { return nil }
        return make(modelRevision: entry.version, assetManifestHash: assetManifestHash(of: entry), voiceStyleHash: voiceFile.sha256)
    }

    public static func make(modelRevision: String, assetManifestHash: String, voiceStyleHash: String) -> TTSRenderSignature {
        let parametersHash = sha256(synthesisParameters)
        let canonical = [
            PhononVoice.engine,
            modelRevision,
            assetManifestHash,
            voiceStyleHash,
            parametersHash,
            normalizationVersion,
            chunkingVersion,
            "prepared-audio-manifest.v2",
        ].joined(separator: "\u{1f}")
        return TTSRenderSignature(
            engine: PhononVoice.engine,
            modelRevision: modelRevision,
            assetManifestHash: assetManifestHash,
            voiceStyleHash: voiceStyleHash,
            synthesisParametersHash: parametersHash,
            normalizationVersion: normalizationVersion,
            chunkingVersion: chunkingVersion,
            digest: sha256(canonical)
        )
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Phonon's one-time preparation after download (#2700): Core ML compiles the three packages for this device, about
/// 10 s on an iPhone 16 Pro (Gradium's figure), so Settings shows "Preparing voice" once instead of the first
/// paragraph stalling. `compile` is the app's `Phonon.load` on the staged folder, which writes each `.mlmodelc`
/// beside its package, inside the folder, as the installer requires.
public struct PhononVoicePreparation: VoiceModelPreparing {
    public typealias Compile = @Sendable (PhononModelLocation) async throws -> Void

    private let compile: Compile

    public init(compile: @escaping Compile) { self.compile = compile }

    public var needsPreparation: Bool { true }

    public func prepare(stagedFolder: URL, entry: VoiceModelEntry) async throws {
        let location = PhononModelLocation(rootURL: stagedFolder)
        try location.validate()
        // A compile cut off earlier can leave a partial `.mlmodelc`, which `Phonon.load` would take as finished and
        // fail on at the first paragraph. Start clean.
        for package in PhononModelLocation.modelPackages {
            let compiled = location.compiledURL(of: package)
            if FileManager.default.fileExists(atPath: compiled.path) { try FileManager.default.removeItem(at: compiled) }
        }
        try Task.checkCancellation()
        try await compile(location)
        if let missing = location.uncompiledPackages().first { throw PhononModelError.notCompiled(missing) }
    }
}
