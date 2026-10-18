import Foundation
import SessionKit
import SessionKitSupertonic

/// Supertonic's model is a download, no longer part of the app (#1820). When the listener's voice is James or Lily
/// and the model isn't downloaded, the player is built as usual, but Supertonic may never render: the bundled Kitten
/// voice reads every passage (the iOS voice, when Kitten's files can't be opened), and Supertonic audio already
/// saved on the phone still plays. This stands in for Supertonic's renderer, so the player needs no second path.
/// Nothing downloads on its own; the listener downloads Supertonic in Settings › Voices.
struct SupertonicModelNotDownloaded: SupertonicRendering {
    /// What diagnostics show as the session's voice.
    static let sessionDescription = "Kitten (Supertonic not downloaded)"
    /// The code logged when Kitten takes over for this reason, in place of a hot or pressed phone's.
    static let fallbackCode = "supertonic_not_downloaded"

    /// The player's "may Supertonic render now?" while the model isn't there: never.
    static let renderingAllowed: @Sendable () -> Bool = { false }
    /// The same question once it is there: the phone's heat, memory and power decide, as always.
    static let governorAllowsRendering: @Sendable () -> Bool = { OnDeviceVoiceGovernor.app.supertonicRenderingBlock() == nil }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        throw SupertonicNarrationError.missingAsset("Supertonic")
    }

    /// It never made a file, so it has none to delete. Kitten's own files go through Kitten.
    func discardGeneratedAudio(at url: URL) async {}
}
