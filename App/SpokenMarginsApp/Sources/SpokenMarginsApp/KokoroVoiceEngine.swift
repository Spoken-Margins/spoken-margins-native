import Foundation
import SessionKit
import SessionKitSpeechFrontEnd
import SessionKitSupertonic

/// Kokoro (`kokoro-82m`, #2705) as the speech player and Settings › Voices see it (#2700).
enum KokoroVoiceEngine {
    /// Kokoro's player and its one-time Core ML compile and lexicon build, registered with the shared voice
    /// registry (#2744).
    static let registration: DownloadedVoiceRegistration? = DownloadedVoiceRegistration(
        makeRenderer: { KokoroDownloadedVoiceRenderer(voice: $0, installedFolder: $1) },
        preparer: KokoroModelPreparer(buildLexicon: { gold, silver in try MisakiLexicon.tsv(goldJSON: gold, silverJSON: silver) })
    )

    static let descriptor = DownloadedVoiceDescriptor(
        voiceId: ReadingVoiceChoice.kokoroVoiceId,
        choice: .kokoro,
        runtime: VoiceModelCatalogVerifier.coreMLRuntime,
        engine: KokoroRenderSignature.engine,
        speaker: KokoroVoice.defaultVoice,
        // Speed 1: the player always renders at 1 and changes the listening speed at playback.
        identity: { entry, speaker in KokoroRenderSignature.make(voice: speaker, entry: entry, speed: 1) },
        registration: registration
    )
}

/// The speech player's Kokoro renderer. It finds the installed folder at every render, so a voice downloaded after the
/// player was built plays, and one removed since throws instead of reading stale files. It keeps one
/// `KokoroNarrationRenderer` per folder and drops the model when the folder changes. Every result carries
/// `KokoroRenderSignature.engine` (the renderer stamps it), so the player files the chunks as Kokoro's own.
final class KokoroDownloadedVoiceRenderer: SupertonicRendering, @unchecked Sendable {
    private struct Cached {
        let folder: URL
        let renderer: KokoroNarrationRenderer
    }

    /// The voice it reads with: the descriptor's `speaker`, which its saved audio is filed under.
    let voice: String
    private let installedFolder: @Sendable () -> URL?
    private let lock = NSLock()
    private var cached: Cached?
    private var eventSink: @Sendable (String, [String: String]) -> Void = { _, _ in }

    init(voice: String, installedFolder: @escaping @Sendable () -> URL?) {
        self.voice = voice
        self.installedFolder = installedFolder
    }

    var engine: String { KokoroNarrationRenderer.engine }

    var isLoadingModel: Bool { lock.withLock { cached?.renderer }?.isLoadingModel ?? false }

    func setEventSink(_ sink: @escaping @Sendable (String, [String: String]) -> Void) {
        lock.withLock { eventSink = sink }
    }

    /// Loads the model and runs a short render before the first Play (#2856). Nothing installed, or a renderer that
    /// can't be built, is left for the first Play to report.
    func prepareToRender() async {
        guard let renderer = try? currentRenderer() else { return }
        await renderer.warmUp()
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        let renderer = try currentRenderer()
        return try await renderer.render(text: text, speed: speed, pacing: .whenAppBackgrounded)
    }

    func discardGeneratedAudio(at url: URL) async {
        let renderer = lock.withLock { cached?.renderer }
        await renderer?.discardGeneratedAudio(at: url)
    }

    private func currentRenderer() throws -> KokoroNarrationRenderer {
        guard let folder = installedFolder() else { throw KokoroNarrationRenderer.RenderError.missingFile(KokoroVoice.catalogId) }
        guard let kitten = Bundle.main.resourceURL?.appending(path: "Kitten", directoryHint: .isDirectory) else {
            throw KokoroNarrationRenderer.RenderError.missingFile("Kitten")
        }
        return try lock.withLock {
            if let cached, cached.folder == folder { return cached.renderer }
            let sink = eventSink
            if let previous = cached?.renderer { Task { await previous.unload() } }
            let renderer = try KokoroNarrationRenderer(
                voiceFolder: folder,
                kittenAssets: KittenAssetLocation(rootURL: kitten),
                voice: voice,
                outputDirectory: FileManager.default.temporaryDirectory.appending(path: "KokoroNarration", directoryHint: .isDirectory),
                governor: .app,
                events: { kind, fields in sink(kind, fields) }
            )
            cached = Cached(folder: folder, renderer: renderer)
            return renderer
        }
    }
}
