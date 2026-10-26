import Foundation

/// The identity a downloaded voice's saved audio is filed under (#64, #2700), for the catalog voices that aren't
/// Supertonic (Phonon #2704, Kokoro #2705). Built from the catalog entry alone, with no file read at play time: the
/// catalog's per-file SHA-256s already name the exact bytes the installer checked, so audio saved before a Remove, or
/// before a re-download of the same version, keeps its identity, and a new model version gets a new one.
///
/// The renderer that plays this voice must stamp its own chunks with the same `engine`, or the prepared-audio
/// coordinator files them as stand-ins (its engine match).
public enum DownloadedVoiceRenderIdentity {
    /// - Parameters:
    ///   - engine: the engine name the voice's renderer writes into each result.
    ///   - entry: the voice's catalog entry; its version and file hashes name the model.
    ///   - speaker: the voice inside the model (Kokoro's `af_heart`, say).
    ///   - parameters: synthesis settings that change the audio (speed, steps); their order doesn't matter.
    ///   - normalizationVersion: the text front end's version, so a change to it re-renders.
    ///   - chunkingVersion: how narration is cut into chunks; the app's planner by default.
    public static func make(
        engine: String,
        entry: VoiceModelEntry,
        speaker: String,
        parameters: [String: String] = [:],
        normalizationVersion: String,
        chunkingVersion: String = NarrationChunkPlanner.version
    ) -> TTSRenderSignature {
        let assetHash = assetManifestHash(of: entry)
        let speakerHash = sha256("speaker=\(speaker)")
        let parametersHash = sha256(
            parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1f}")
        )
        let canonical = [
            engine,
            entry.version,
            assetHash,
            speakerHash,
            parametersHash,
            normalizationVersion,
            chunkingVersion,
            "prepared-audio-manifest.v2"
        ].joined(separator: "\u{1f}")
        return TTSRenderSignature(
            engine: engine,
            modelRevision: entry.version,
            assetManifestHash: assetHash,
            voiceStyleHash: speakerHash,
            synthesisParametersHash: parametersHash,
            normalizationVersion: normalizationVersion,
            chunkingVersion: chunkingVersion,
            digest: sha256(canonical)
        )
    }

    /// SHA-256 over the entry's files, each as its path and SHA-256, sorted by path so the catalog's order doesn't
    /// matter. Licence and notice files count too: they are part of what the installer checks.
    public static func assetManifestHash(of entry: VoiceModelEntry) -> String {
        let lines = entry.files
            .sorted { $0.path < $1.path }
            .map { "\($0.path)\u{1f}\($0.sha256.lowercased())" }
        return sha256(lines.joined(separator: "\n"))
    }

    private static func sha256(_ text: String) -> String {
        SourceCatalogVerifier.sha256(Data(text.utf8))
    }
}
