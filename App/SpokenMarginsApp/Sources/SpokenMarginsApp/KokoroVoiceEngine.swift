import Foundation
import SessionKit

/// Kokoro (`kokoro-82m`, #2705) as the speech player and Settings › Voices see it (#2700).
enum KokoroVoiceEngine {
    /// The Kokoro slice registers here, and only here: replace `nil` with
    /// `DownloadedVoiceRegistration(makeRenderer: { KokoroNarrationRenderer(installedFolder: $0) }, preparer: KokoroCoreMLPreparer())`.
    /// While it is nil, Kokoro is not offered for download, not listed in the App Voice picker, and never played.
    static let registration: DownloadedVoiceRegistration? = nil

    static let descriptor = DownloadedVoiceDescriptor(
        voiceId: ReadingVoiceChoice.kokoroVoiceId,
        choice: .kokoro,
        runtime: VoiceModelCatalogVerifier.coreMLRuntime,
        engine: "kokoro",
        speaker: "af_heart",
        normalizationVersion: "kokoro-text.v1",
        registration: registration
    )
}
