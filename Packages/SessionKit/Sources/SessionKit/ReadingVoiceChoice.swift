import Foundation

/// The reading voices a listener can pick in Settings (#2226), by the codes the app stores in `ttsVoiceSelection`.
/// The three codes James, Lily and the iOS voice have used since the first builds keep their spelling, so a database
/// or settings file written by an older build still reads the same voice; `kitten:jasper` is new, and a build that
/// predates it treats it as an unknown value and falls back to its default. The downloaded Neural Engine voices
/// (#2700), Phonon (#2704) and Kokoro (#2705), are new in the same way.
public enum ReadingVoiceChoice: String, CaseIterable, Sendable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    /// The voice bundled in the app (#849). No download, no Supertonic model.
    case kitten = "kitten:jasper"
    case system = "system"
    /// Phonon, downloaded in Settings › Voices (#2704). Offered on A14 and newer.
    case phonon = "phonon:en"
    /// Kokoro, downloaded in Settings › Voices (#2705). Offered on A14 and newer.
    case kokoro = "kokoro:af_heart"

    public static let phononVoiceId = "phonon-31m-en"
    public static let kokoroVoiceId = "kokoro-82m"

    /// Read by the app's own on-device player (Supertonic, Kitten or a downloaded voice) rather than by the iOS voice.
    public var readsOnDevice: Bool { self != .system }

    /// Supertonic renders the narration, so the voice needs its download and its saved audio can play.
    public var rendersWithSupertonic: Bool { self == .james || self == .lily }

    /// The voice's id in the voice catalog when it is a download other than Supertonic (Phonon, Kokoro), else nil.
    public var downloadedVoiceId: String? {
        switch self {
        case .phonon: Self.phononVoiceId
        case .kokoro: Self.kokoroVoiceId
        case .james, .lily, .kitten, .system: nil
        }
    }

    /// Whether Supertonic's saved audio (prepared chunks and the render cache) may play for this choice. A listener
    /// who picked Kitten, Phonon or Kokoro never hears Supertonic, even where Supertonic audio happens to be saved.
    public var playsSavedSupertonicAudio: Bool { rendersWithSupertonic }

    /// Whether the chosen voice's own saved audio (prepared chunks) may play: Supertonic's for James and Lily, the
    /// downloaded voice's for Phonon and Kokoro. This is what lets a saved run of the chosen voice take over from
    /// Kitten at a seam on a hot phone (#1680). Kitten and the iOS voice have no chosen-voice audio of their own here.
    public var playsSavedChosenVoiceAudio: Bool { rendersWithSupertonic || downloadedVoiceId != nil }

    /// Whether the bundled voice reading is the listener's choice rather than a stand-in for Supertonic, so its
    /// takeover needs no "Supertonic isn't available" notice.
    public var bundledVoiceIsChosen: Bool { self == .kitten }
}
