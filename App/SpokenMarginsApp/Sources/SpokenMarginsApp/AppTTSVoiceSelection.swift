import Foundation
import SessionKitSupertonic

enum AppTTSVoiceSelection: String, CaseIterable, Identifiable {
    case james = "supertonic:M2"
    case lily = "supertonic:F2"
    case system = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .james: "James"
        case .lily: "Lily"
        case .system: "iOS System Voice"
        }
    }

    var detail: String {
        switch self {
        case .james: "Deep, calm · M2"
        case .lily: "Bright, cheerful · F2"
        case .system: "Uses the selected voice installed in iOS"
        }
    }

    var supertonicVoice: SupertonicVoiceID? {
        switch self {
        case .james: .m2
        case .lily: .f2
        case .system: nil
        }
    }
}
