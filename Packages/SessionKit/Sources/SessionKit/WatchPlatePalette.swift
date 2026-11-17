import Foundation

/// An sRGB colour on the Watch. The Watch app compiles this file on its own (it does not link SessionKit), so the type is
/// defined here and the contrast audit converts it to `AppColorRGB`.
public struct WatchPlateColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// The coloured plates the Watch draws (#3731).
public enum WatchPlate: String, CaseIterable, Sendable {
    /// The single Record with nothing loaded.
    case record
    /// "On this episode", and Stop after recording on it.
    case episode
    /// "On the session", and Stop after recording on it.
    case session
    case discard
    case transport
}

/// The fill and label colour of every Watch plate, read by `SpokenMarginsWatchApp` and by the contrast audit in
/// `ExperienceColorContrast.swift`, so a plate cannot change colour without its pair changing too. Foundation only.
///
/// watchOS has one appearance and the screen is black, so a plate's fill is measured composited over black.
public enum WatchPlatePalette {
    /// A pressed plate draws its fill at `alpha * pressedMultiplier`. It was 0.6, which put the session plate's dark words
    /// at about 3.1:1; at 0.8 they stay above 5:1 and the press still shows.
    public static let pressedMultiplier = 0.8

    public static let watchBlack = WatchPlateColor(red: 0, green: 0, blue: 0)

    /// A deep blue (white on it is 5.76:1) in place of the system blue (3.65:1).
    private static let deepBlue = WatchPlateColor(red: 0, green: 0.376, blue: 0.839)
    private static let sessionOrange = WatchPlateColor(red: 1, green: 0.624, blue: 0.039)
    /// The value of `AppSemanticColorRGB.watchBackground`; `WatchPlatePaletteTests` fails if the two drift.
    private static let nearBlack = WatchPlateColor(red: 0.09, green: 0.13, blue: 0.11)
    private static let white = WatchPlateColor(red: 1, green: 1, blue: 1)

    /// The plate's fill colour and the alpha it is drawn at.
    public static func fill(_ plate: WatchPlate) -> (color: WatchPlateColor, alpha: Double) {
        switch plate {
        case .record, .episode: return (deepBlue, 1)
        case .session: return (sessionOrange, 1)
        // The dark value of `AppSystemColorRGB.red`, drawn at 0.85 as before.
        case .discard: return (WatchPlateColor(red: 1, green: 0.271, blue: 0.227), 0.85)
        case .transport: return (WatchPlateColor(red: 0.557, green: 0.557, blue: 0.576), 0.4)
        }
    }

    /// The colour of the words and icon on the plate: dark on the orange, white on the rest.
    public static func label(_ plate: WatchPlate) -> WatchPlateColor {
        plate == .session ? nearBlack : white
    }

    /// The target's name in the recording header, drawn on black. The deep blue is a fill colour and is 3.64:1 as text, so
    /// the header keeps the bright system blue. Only the two targets have a header; `.record` reads as the episode, and a
    /// plate with no header gets its label colour.
    public static func headerText(_ plate: WatchPlate) -> WatchPlateColor {
        switch plate {
        case .record, .episode: return WatchPlateColor(red: 0.039, green: 0.518, blue: 1)
        case .session: return sessionOrange
        case .discard, .transport: return label(plate)
        }
    }

    /// The plate Stop is drawn on: the recording's target, and the session plate when no target was shown.
    public static func stopPlate(for target: WatchPlate?) -> WatchPlate {
        target == .episode ? .episode : .session
    }
}
