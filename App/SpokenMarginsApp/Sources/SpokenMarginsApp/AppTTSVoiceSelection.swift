import Foundation
import SessionKit
import SessionKitSupertonic

enum AppTTSVoiceSelection: String, CaseIterable, Identifiable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    case kitten = "kitten:jasper"
    case system = "system"

    var id: String { rawValue }

    /// The same choice in SessionKit, where its rules are host-tested (#2226). The switch keeps the two lists equal.
    var choice: ReadingVoiceChoice {
        switch self {
        case .james: .james
        case .lily: .lily
        case .kitten: .kitten
        case .system: .system
        }
    }

    var displayName: String {
        switch self {
        case .james: "James"
        case .lily: "Lily"
        case .kitten: "Kitten (Jasper)"
        case .system: "iOS System Voice"
        }
    }

    var detail: String {
        switch self {
        case .james: "Deep, calm · M2"
        case .lily: "Bright, cheerful · F2"
        case .kitten: "Built into the app · no download"
        case .system: "Uses the selected voice installed in iOS"
        }
    }

    /// The Supertonic voice that renders this choice; nil for Kitten and the iOS voice.
    var supertonicVoice: SupertonicVoiceID? {
        switch self {
        case .james: .m2
        case .lily: .f2
        case .kitten, .system: nil
        }
    }

    /// Read by the app's on-device player (Supertonic or Kitten), not the iOS voice. These choices need the Terms.
    var isOnDeviceVoice: Bool { choice.readsOnDevice }
}
