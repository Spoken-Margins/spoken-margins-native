import Foundation
import SessionKit
import SessionKitSupertonic

/// Supertonic's model is a download, no longer part of the app (#1820). When the listener's voice is James or Lily
/// and the model isn't downloaded, the player is built as usual, but Supertonic may not render: the bundled Kitten
/// voice reads every passage (the iOS voice, when Kitten's files can't be opened). Saved Supertonic audio still plays,
/// because its identity comes from the hashes pinned in `asset-manifest.json` (`SupertonicRenderIdentity.current`).
/// Nothing downloads on its own; the listener downloads Supertonic in Settings › Voices.
enum SupertonicModelNotDownloaded {
    /// What diagnostics show as the session's voice.
    static let sessionDescription = "Kitten (Supertonic not downloaded)"
    /// The code logged when Kitten takes over for this reason, in place of a hot or pressed phone's.
    static let fallbackCode = "supertonic_not_downloaded"

    /// The status line when "Try App Voice" plays Kitten's sample for James or Lily (#2219).
    static func previewMessage(voiceName: String) -> String {
        "\(voiceName) needs the Supertonic download, so this sample is Kitten, the voice reading to you now. Download Supertonic in Settings › Voices."
    }

    /// Once the model is there, the phone's heat, memory and power decide, as always.
    static let governorAllowsRendering: @Sendable () -> Bool = { OnDeviceVoiceGovernor.app.supertonicRenderingBlock() == nil }
}

/// The speech player's Supertonic renderer (#1820). It asks the app model for the renderer at every render, so it
/// renders with the model on the phone now: one downloaded after the player was built, or none after a Remove. The
/// player asks `SupertonicModelFollower.renderingAllowed` before each passage, so with no model it never gets here.
struct SupertonicDownloadedModelRenderer: SupertonicRendering {
    private let resolve: @MainActor @Sendable () throws -> SupertonicNarrationRenderer
    private let current: @MainActor @Sendable () -> SupertonicNarrationRenderer?

    init(model: Gate1AppModel) {
        resolve = { [weak model] in
            guard let model else { throw SupertonicNarrationError.missingAsset("Supertonic") }
            return try model.makeSupertonicRenderer()
        }
        current = { [weak model] in model?.supertonicRenderer }
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        let renderer = try await resolve()
        return try await renderer.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
    }

    func discardGeneratedAudio(at url: URL) async {
        await current()?.discardGeneratedAudio(at: url)
    }
}
