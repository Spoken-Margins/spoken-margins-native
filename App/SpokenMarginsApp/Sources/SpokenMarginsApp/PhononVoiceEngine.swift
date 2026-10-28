import Foundation
import SessionKit
import SessionKitSupertonic

/// Phonon (`phonon-31m-en`, #2704) as the speech player and Settings › Voices see it (#2700).
enum PhononVoiceEngine {
    /// Phonon's player and its one-time Core ML compile, registered with the shared voice registry (#2744).
    static let registration: DownloadedVoiceRegistration? = DownloadedVoiceRegistration(
        makeRenderer: { PhononDownloadedVoiceRenderer(voiceName: $0, installedFolder: $1) },
        preparer: PhononTTSEngine.preparation
    )

    static let descriptor = DownloadedVoiceDescriptor(
        voiceId: ReadingVoiceChoice.phononVoiceId,
        choice: .phonon,
        runtime: VoiceModelCatalogVerifier.phononRuntime,
        engine: PhononVoice.engine,
        speaker: PhononVoice.defaultVoiceName,
        identity: { entry, speaker in PhononRenderSignature.make(entry: entry, voice: speaker) },
        registration: registration
    )
}

/// The speech player's Phonon renderer. It finds the installed folder at every render, so a voice downloaded after the
/// player was built plays, and one removed since throws instead of reading stale files. It keeps one
/// `PhononNarrationRenderer` per folder and drops the model when the folder changes. Every result carries
/// `PhononVoice.engine` (the renderer stamps it), so the player files the chunks as Phonon's own.
final class PhononDownloadedVoiceRenderer: SupertonicRendering, @unchecked Sendable {
    private struct Cached {
        let folder: URL
        let renderer: PhononNarrationRenderer
    }

    /// The voice it reads with: the descriptor's `speaker`, which its saved audio is filed under.
    let voiceName: String
    private let installedFolder: @Sendable () -> URL?
    private let lock = NSLock()
    private var cached: Cached?

    init(voiceName: String, installedFolder: @escaping @Sendable () -> URL?) {
        self.voiceName = voiceName
        self.installedFolder = installedFolder
    }

    var engine: String { PhononNarrationRenderer.engine }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        let renderer = try currentRenderer()
        return try await renderer.render(text: text)
    }

    /// Background preparation renders at `.always` pacing (#2857).
    func pacedForBackgroundPreparation() -> any SupertonicRendering { Paced(base: self) }

    private struct Paced: SupertonicRendering {
        let base: PhononDownloadedVoiceRenderer
        var engine: String { base.engine }
        func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
            try await base.currentRenderer().render(text: text, pacing: .always)
        }
        func discardGeneratedAudio(at url: URL) async { await base.discardGeneratedAudio(at: url) }
    }

    func discardGeneratedAudio(at url: URL) async {
        let renderer = lock.withLock { cached?.renderer }
        await renderer?.discardGeneratedAudio(at: url)
    }

    fileprivate func currentRenderer() throws -> PhononNarrationRenderer {
        guard let folder = installedFolder() else { throw PhononModelError.missingAsset(PhononVoice.catalogId) }
        return try lock.withLock {
            if let cached, cached.folder == folder { return cached.renderer }
            let previous = cached?.renderer
            if let previous { Task { await previous.unload() } }
            let renderer = try PhononNarrationRenderer(
                location: PhononModelLocation(rootURL: folder),
                voiceName: voiceName,
                outputDirectory: FileManager.default.temporaryDirectory.appending(path: "PhononNarration", directoryHint: .isDirectory),
                governor: .app,
                load: PhononTTSEngine.load
            )
            cached = Cached(folder: folder, renderer: renderer)
            return renderer
        }
    }
}
