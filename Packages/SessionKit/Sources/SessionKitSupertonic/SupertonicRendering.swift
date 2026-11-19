import Foundation
import SessionKit

/// What the narration player renders a chunk with: Supertonic's own renderer, `SupertonicOutputGuard` around it, or a
/// downloaded voice's renderer. In the package so the guard and its tests run on the host (#318).
public protocol SupertonicRendering: VoiceWarmUpRendering {
    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult

    func discardGeneratedAudio(at url: URL) async

    /// The engine name this renderer's own audio carries (#2700). The player counts a chunk as the chosen voice's
    /// own audio, not a stand-in, only when its result says this engine. Supertonic by default; a downloaded voice's
    /// renderer returns its descriptor's engine.
    var engine: String { get }

    /// This renderer as background preparation must use it: paced whatever the app's state, so it never competes with
    /// live narration for CPU (#377). Supertonic has `BackgroundPreparationRenderer` for that; a downloaded voice's
    /// renderer returns a view of itself that renders with `.always` pacing (#2857).
    func pacedForBackgroundPreparation() -> any SupertonicRendering

    /// True while the renderer is loading its model for the first time (a Neural Engine voice loads and specialises
    /// its Core ML models then, which can take longer than the player's usual wait). The player doesn't give a
    /// waiting listener's passage to the iOS voice for being slow while this is true, up to
    /// `SupertonicSpeechPlaybackClient.maxModelLoadExtensions` more waits (#2856).
    var isLoadingModel: Bool { get }

    // `prepareToRender()` comes from `VoiceWarmUpRendering` (SessionKit); the default below does nothing.

    /// Where a renderer reports its own events (`voice.load`) for the diagnostics export: voice, timing and error text,
    /// never source text.
    func setEventSink(_ sink: @escaping @Sendable (_ kind: String, _ fields: [String: String]) -> Void)
}

extension SupertonicRendering {
    public var engine: String { SupertonicNarrationResult.supertonicEngine }
    public func pacedForBackgroundPreparation() -> any SupertonicRendering { self }
    public var isLoadingModel: Bool { false }
    public func prepareToRender() async {}
    public func setEventSink(_ sink: @escaping @Sendable (_ kind: String, _ fields: [String: String]) -> Void) {}
}

/// Supertonic's own renderer has no downloaded model to warm, so the default `prepareToRender()` (nothing) is its
/// witness (#2856).
extension SupertonicNarrationRenderer: SupertonicRendering {}
