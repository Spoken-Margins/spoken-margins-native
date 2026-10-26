import Foundation
import SessionKit

/// Phonon (`phonon-31m-en`, #2704) as the speech player and Settings › Voices see it (#2700).
enum PhononVoiceEngine {
    /// The Phonon slice registers here, and only here: replace `nil` with
    /// `DownloadedVoiceRegistration(makeRenderer: { PhononNarrationRenderer(installedFolder: $0) }, preparer: PhononVoicePreparer())`.
    /// While it is nil, Phonon is not offered for download, not listed in the App Voice picker, and never played.
    static let registration: DownloadedVoiceRegistration? = nil

    static let descriptor = DownloadedVoiceDescriptor(
        voiceId: ReadingVoiceChoice.phononVoiceId,
        choice: .phonon,
        runtime: VoiceModelCatalogVerifier.phononRuntime,
        engine: "phonon",
        speaker: "en",
        normalizationVersion: "phonon-text.v1",
        registration: registration
    )
}
