import Foundation
import SessionKit
import SessionKitSupertonic

enum AppTTSVoiceSelection: String, CaseIterable, Identifiable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    case kitten = "kitten:jasper"
    case system = "system"
    case phonon = "phonon:en"
    case kokoro = "kokoro:af_heart"

    var id: String { rawValue }

    /// The same choice in SessionKit, where its rules are host-tested (#2226). The switch keeps the two lists equal.
    var choice: ReadingVoiceChoice {
        switch self {
        case .james: .james
        case .lily: .lily
        case .kitten: .kitten
        case .system: .system
        case .phonon: .phonon
        case .kokoro: .kokoro
        }
    }

    init(choice: ReadingVoiceChoice) {
        switch choice {
        case .james: self = .james
        case .lily: self = .lily
        case .kitten: self = .kitten
        case .system: self = .system
        case .phonon: self = .phonon
        case .kokoro: self = .kokoro
        }
    }

    /// What the App Voice picker lists (#2700): the voices that need no download of their own, plus each downloaded
    /// voice that has a player, is installed and may run on this chip, plus `current` whatever it is.
    @MainActor
    static func pickerChoices(current: AppTTSVoiceSelection, rows: [VoiceCatalogRow]) -> [AppTTSVoiceSelection] {
        ReadingVoiceOffer.choices(current: current.choice, rows: rows, playableVoiceIds: VoiceDownloadsModel.playableVoiceIds)
            .map(AppTTSVoiceSelection.init(choice:))
    }

    var displayName: String {
        switch self {
        case .james: "James"
        case .lily: "Lily"
        case .kitten: "Kitten (Jasper)"
        case .system: "iOS System Voice"
        case .phonon: "Phonon"
        case .kokoro: "Kokoro"
        }
    }

    var detail: String {
        switch self {
        case .james: "Deep, calm · M2"
        case .lily: "Bright, cheerful · F2"
        case .kitten: "Built into the app · no download"
        case .system: "Uses the selected voice installed in iOS"
        case .phonon: "Downloaded · Neural Engine"
        case .kokoro: "Downloaded · Neural Engine"
        }
    }

    /// The Supertonic voice that renders this choice; nil for Kitten, the iOS voice and the downloaded voices.
    var supertonicVoice: SupertonicVoiceID? {
        switch self {
        case .james: .m2
        case .lily: .f2
        case .kitten, .system, .phonon, .kokoro: nil
        }
    }

    /// Read by the app's on-device player (Supertonic or Kitten), not the iOS voice. These choices need the Terms.
    var isOnDeviceVoice: Bool { choice.readsOnDevice }
}
