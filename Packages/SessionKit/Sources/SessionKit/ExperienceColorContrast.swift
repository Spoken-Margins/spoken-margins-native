import Foundation

/// The app's semantic colours as plain numbers, and the contrast audit over them. Foundation only, so the
/// WCAG check runs on the host (moved from the app target, #318).
public struct AppColorRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    fileprivate var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

public struct AppDynamicRGB: Equatable, Sendable {
    public let light: AppColorRGB
    public let dark: AppColorRGB

    public init(light: AppColorRGB, dark: AppColorRGB) {
        self.light = light
        self.dark = dark
    }
}

extension AppColorRGB {
    /// This colour drawn at `alpha` over `base`: the straight-alpha blend SwiftUI's `.opacity` makes, in the same
    /// colour space the other numbers here are in. The audit needs it because a tint is never read alone; the text
    /// sits on the tint over whatever is behind it (#3739).
    public func composited(over base: AppColorRGB, alpha: Double) -> AppColorRGB {
        let a = min(max(alpha, 0), 1)
        return AppColorRGB(
            red: red * a + base.red * (1 - a),
            green: green * a + base.green * (1 - a),
            blue: blue * a + base.blue * (1 - a)
        )
    }
}

extension AppDynamicRGB {
    /// `AppColorRGB.composited(over:alpha:)` in each appearance.
    public func composited(over base: AppDynamicRGB, alpha: Double) -> AppDynamicRGB {
        AppDynamicRGB(
            light: light.composited(over: base.light, alpha: alpha),
            dark: dark.composited(over: base.dark, alpha: alpha)
        )
    }
}

/// The system colours the app draws with directly, as Apple publishes them (the sRGB values of the system palette as
/// the audit issues quote them; iOS 26 may have shifted some, which would move a ratio and not the fact that it fails). They are
/// here so the audit can measure a pair that names one, instead of the pair being invisible to it (#3739). A new use
/// of a system colour outside the allowlist in the guard tests fails; the way out is a token in `AppSemanticColorRGB`.
public enum AppSystemColorRGB {
    public static let red = AppDynamicRGB(light: .init(red: 1, green: 0.231, blue: 0.188), dark: .init(red: 1, green: 0.271, blue: 0.227))
    public static let orange = AppDynamicRGB(light: .init(red: 1, green: 0.584, blue: 0), dark: .init(red: 1, green: 0.624, blue: 0.039))
    public static let yellow = AppDynamicRGB(light: .init(red: 1, green: 0.8, blue: 0), dark: .init(red: 1, green: 0.839, blue: 0.039))
    public static let green = AppDynamicRGB(light: .init(red: 0.204, green: 0.78, blue: 0.349), dark: .init(red: 0.188, green: 0.82, blue: 0.345))
    public static let blue = AppDynamicRGB(light: .init(red: 0, green: 0.478, blue: 1), dark: .init(red: 0.039, green: 0.518, blue: 1))

    /// The Live Activity draws on one fixed dark plate in both appearances (`activityBackgroundTint`). The progress blue and the
    /// second green are literals in the widget.
    private static func fixed(_ red: Double, _ green: Double, _ blue: Double) -> AppDynamicRGB {
        let color = AppColorRGB(red: red, green: green, blue: blue)
        return AppDynamicRGB(light: color, dark: color)
    }
    public static let liveActivityPlate = fixed(0.08, 0.09, 0.12)
    public static let liveActivityProgress = fixed(0.34, 0.71, 0.91)
    public static let liveActivityGreen = fixed(0.27, 0.78, 0.43)
    /// Neither widget sets a colour scheme, so a system colour may resolve to either of its values on the Lock Screen: these are the
    /// system colours as they are, light and dark, and the audit measures both.
    public static let liveActivityRed = red
    public static let liveActivityOrange = orange
    public static let liveActivityGreenSystem = green
    /// The Dynamic Island is always black, and its secondary label is the system's dark secondary: white-grey at 60%.
    public static let dynamicIslandBlack = fixed(0, 0, 0)
    public static let darkSecondaryLabel = fixed(0.922, 0.922, 0.961)

    /// UIKit's own surface and label colours, as the share extension draws them (#3739 slice 4): the card is
    /// `secondarySystemBackground` (#F2F2F7 light, #1C1C1E dark) and its words are `label` (black, white).
    public static let secondarySystemBackground = AppDynamicRGB(
        light: .init(red: 242.0 / 255, green: 242.0 / 255, blue: 247.0 / 255),
        dark: .init(red: 28.0 / 255, green: 28.0 / 255, blue: 30.0 / 255)
    )
    public static let label = AppDynamicRGB(light: .init(red: 0, green: 0, blue: 0), dark: .init(red: 1, green: 1, blue: 1))
}

/// The colours of the Safari extension's popup (`popup.css`): one fixed palette, written as hex in the stylesheet, which
/// the popup draws in both appearances. The guard tests read every hex literal in the stylesheet and fail on one that is
/// not listed here, so a new colour needs a pair in `AppColorContrastAudit.safariPopupPairs` (#3739 slice 4).
public enum AppSafariPopupRGB {
    /// The six-digit hex (lower case, no `#`) of each colour the stylesheet may use, and the colour it is.
    public static let palette: [String: AppDynamicRGB] = {
        let hexes = ["f6f6f6", "101312", "57d696", "07110d", "aeb8b3", "111111", "bdbdbd"]
        return Dictionary(uniqueKeysWithValues: hexes.map { ($0, fixed(hex: $0)) })
    }()

    public static func fixed(hex: String) -> AppDynamicRGB {
        precondition(hex.count == 6, "a six-digit hex")
        let value = UInt32(hex, radix: 16) ?? 0
        let color = AppColorRGB(
            red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255
        )
        return AppDynamicRGB(light: color, dark: color)
    }

    public static var text: AppDynamicRGB { fixed(hex: "f6f6f6") }
    public static var plate: AppDynamicRGB { fixed(hex: "101312") }
    public static var accent: AppDynamicRGB { fixed(hex: "57d696") }
    public static var markText: AppDynamicRGB { fixed(hex: "07110d") }
    public static var caption: AppDynamicRGB { fixed(hex: "aeb8b3") }
    public static var buttonText: AppDynamicRGB { fixed(hex: "111111") }
    public static var status: AppDynamicRGB { fixed(hex: "bdbdbd") }
}

public enum AppSemanticColorRGB {
    private static func fixed(_ red: Double, _ green: Double, _ blue: Double) -> AppDynamicRGB {
        let color = AppColorRGB(red: red, green: green, blue: blue)
        return AppDynamicRGB(light: color, dark: color)
    }

    public static let listeningBackground = fixed(0.09, 0.224, 0.184)
    public static let captureBackground = fixed(1, 0.941, 0.745)
    public static let listeningAccent = fixed(0.859, 0.929, 0.553)
    public static let listeningSecondary = fixed(0.69, 0.75, 0.70)
    public static let captureText = fixed(0.08, 0.10, 0.08)
    public static let white = fixed(1, 1, 1)
    public static let bone = AppDynamicRGB(
        light: .init(red: 0.97, green: 0.95, blue: 0.89),
        dark: .init(red: 0.08, green: 0.10, blue: 0.09)
    )
    public static let background = AppDynamicRGB(
        light: .init(red: 0.96, green: 0.97, blue: 0.94),
        dark: .init(red: 0.07, green: 0.09, blue: 0.08)
    )
    public static let panel = AppDynamicRGB(
        light: .init(red: 1, green: 1, blue: 1),
        dark: .init(red: 0.13, green: 0.16, blue: 0.14)
    )
    public static let text = AppDynamicRGB(
        light: .init(red: 0.09, green: 0.13, blue: 0.11),
        dark: .init(red: 0.92, green: 0.95, blue: 0.91)
    )
    public static let secondaryText = AppDynamicRGB(
        light: .init(red: 0.37, green: 0.43, blue: 0.40),
        dark: .init(red: 0.66, green: 0.72, blue: 0.68)
    )
    /// The filled primary button's fill, under a white label. A fill only, never a tint: as a `.bordered` tint it is
    /// 1.9:1 in dark mode (#4953), and `AppColorUsageGuardTests.classifiedTintTokens` leaves it out on purpose.
    public static let primaryAction = AppDynamicRGB(
        light: .init(red: 0.08, green: 0.32, blue: 0.22),
        dark: .init(red: 0.12, green: 0.36, blue: 0.23)
    )
    public static let plum = AppDynamicRGB(
        light: .init(red: 0.39, green: 0.24, blue: 0.48),
        dark: .init(red: 0.78, green: 0.62, blue: 0.88)
    )
    public static let evergreen = AppDynamicRGB(
        light: .init(red: 0.08, green: 0.30, blue: 0.21),
        dark: .init(red: 0.48, green: 0.84, blue: 0.62)
    )
    public static let onEvergreen = AppDynamicRGB(
        light: .init(red: 1, green: 1, blue: 1),
        dark: .init(red: 0.07, green: 0.09, blue: 0.08)
    )
    public static let softGreen = AppDynamicRGB(
        light: .init(red: 0.91, green: 0.94, blue: 0.88),
        dark: .init(red: 0.18, green: 0.25, blue: 0.20)
    )
    public static let dangerText = AppDynamicRGB(
        light: .init(red: 0.55, green: 0.13, blue: 0.11),
        dark: .init(red: 1, green: 0.55, blue: 0.48)
    )
    /// The hairline around panels, chips and inputs. Faint by design (about 1.4:1 on a panel).
    public static let border = AppDynamicRGB(
        light: .init(red: 0.84, green: 0.87, blue: 0.81),
        dark: .init(red: 0.28, green: 0.34, blue: 0.30)
    )
    /// What `border` becomes under Increase Contrast: 3:1 against the panel and the app background, the WCAG
    /// floor for the edge of a control (#1922).
    public static let borderIncreased = AppDynamicRGB(
        light: .init(red: 0.46, green: 0.51, blue: 0.46),
        dark: .init(red: 0.52, green: 0.60, blue: 0.55)
    )
    public static let dangerBackground = AppDynamicRGB(
        light: .init(red: 0.96, green: 0.88, blue: 0.86),
        dark: .init(red: 0.34, green: 0.15, blue: 0.13)
    )
    public static let inputBackground = AppDynamicRGB(
        light: .init(red: 0.98, green: 0.99, blue: 0.97),
        dark: .init(red: 0.10, green: 0.12, blue: 0.11)
    )
    public static let green = AppDynamicRGB(
        light: .init(red: 0.13, green: 0.43, blue: 0.30),
        dark: .init(red: 0.50, green: 0.84, blue: 0.62)
    )
    public static let accent = AppDynamicRGB(
        light: .init(red: 0.48, green: 0.82, blue: 0.59),
        dark: .init(red: 0.56, green: 0.89, blue: 0.67)
    )
    public static let accentSoft = AppDynamicRGB(
        light: .init(red: 0.67, green: 0.91, blue: 0.72),
        dark: .init(red: 0.25, green: 0.39, blue: 0.28)
    )
    public static let watchBackground = fixed(0.09, 0.13, 0.11)
    public static let watchControl = fixed(0.18, 0.24, 0.21)
    public static let ochre = AppDynamicRGB(
        light: .init(red: 0.76, green: 0.52, blue: 0.16),
        dark: .init(red: 0.94, green: 0.72, blue: 0.32)
    )
    /// Ochre for text and icons (#1920). `ochre` stays the fill and tint colour; in light mode it is 2.8:1 on bone, so
    /// anything that is read or tapped as a mark uses this deeper one, at least 4.5:1 on bone, a panel and soft green.
    /// Dark mode takes ochre's own value, which is 8:1 and more.
    public static let ochreText = AppDynamicRGB(
        light: .init(red: 0.55, green: 0.33, blue: 0.0),
        dark: .init(red: 0.94, green: 0.72, blue: 0.32)
    )
    /// Warning copy and its icon (#1920), in place of the system orange (about 2:1 on white in light mode). The dark
    /// value is the system orange's own dark value, which is already above 7:1.
    public static let warningText = AppDynamicRGB(
        light: .init(red: 0.66, green: 0.28, blue: 0.0),
        dark: .init(red: 1.0, green: 0.624, blue: 0.039)
    )
    public static let coral = AppDynamicRGB(
        light: .init(red: 0.70, green: 0.27, blue: 0.20),
        dark: .init(red: 1.00, green: 0.57, blue: 0.48)
    )
    /// The starred-for-sharing star. A dark amber on light surfaces, where the system yellow was about 1.5:1
    /// on a white panel (#1925); the shape (filled or outline) still carries the state as well.
    public static let star = AppDynamicRGB(
        light: .init(red: 0.68, green: 0.40, blue: 0.0),
        dark: .init(red: 1.0, green: 0.82, blue: 0.30)
    )
    /// The star on a Margin row of the always-dark player (#4173): `star`'s dark value in both appearances, since the player
    /// does not change with the system appearance. The filled or outline shape still carries the state.
    public static let watchStar = fixed(1.0, 0.82, 0.30)
    /// A destructive label on the always-dark playback cards (Stop on-device generation): the dark-mode danger
    /// text in both appearances, since the card does not change with the system appearance (#1925).
    public static let watchDanger = fixed(1, 0.55, 0.48)

    /// The tints of the swipe buttons (#4045). iOS draws a swipe button's icon and words in white in both appearances, but every
    /// token above turns light in dark mode, which left white on a light tint at about 2:1. These are the light-mode values of
    /// `evergreen`, `ochreText`, `plum` and `secondaryText`, fixed in both appearances, so the hues stay and the white stays readable.
    public static let swipeEvergreen = fixed(0.08, 0.30, 0.21)
    public static let swipeOchre = fixed(0.55, 0.33, 0.0)
    public static let swipePlum = fixed(0.39, 0.24, 0.48)
    public static let swipeSlate = fixed(0.37, 0.43, 0.40)

    /// Every token above, by name. `AppColors` in the app builds its colours from these and nowhere else, so
    /// the audit sees every colour the app draws with. A test fails when a token is missing from this list or
    /// from the pairs below (#1921).
    public static let all: [(name: String, color: AppDynamicRGB)] = [
        ("listeningBackground", listeningBackground), ("captureBackground", captureBackground),
        ("listeningAccent", listeningAccent), ("listeningSecondary", listeningSecondary),
        ("captureText", captureText), ("white", white), ("bone", bone), ("background", background),
        ("panel", panel), ("text", text), ("secondaryText", secondaryText), ("primaryAction", primaryAction),
        ("plum", plum), ("evergreen", evergreen), ("onEvergreen", onEvergreen), ("softGreen", softGreen),
        ("dangerText", dangerText), ("dangerBackground", dangerBackground), ("inputBackground", inputBackground),
        ("border", border), ("borderIncreased", borderIncreased), ("green", green), ("accent", accent), ("accentSoft", accentSoft),
        ("watchBackground", watchBackground), ("watchControl", watchControl), ("ochre", ochre), ("ochreText", ochreText),
        ("warningText", warningText), ("coral", coral),
        ("star", star), ("watchStar", watchStar), ("watchDanger", watchDanger),
        ("swipeEvergreen", swipeEvergreen), ("swipeOchre", swipeOchre), ("swipePlum", swipePlum), ("swipeSlate", swipeSlate)
    ]
}

public enum AppColorContrastAudit {
    public struct Pair: Equatable, Sendable {
        public let name: String
        public let foreground: AppDynamicRGB
        public let background: AppDynamicRGB
        public let minimumRatio: Double

        public init(name: String, foreground: AppDynamicRGB, background: AppDynamicRGB, minimumRatio: Double) {
            self.name = name
            self.foreground = foreground
            self.background = background
            self.minimumRatio = minimumRatio
        }
    }

    public static let textBackgroundPairs: [Pair] = [
        .init(name: "reading body on bone", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "reading secondary on bone", foreground: AppSemanticColorRGB.secondaryText, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        // The Library row's Margins tag: the count in bone on a secondaryText fill (#4698).
        .init(name: "bone on secondaryText", foreground: AppSemanticColorRGB.bone, background: AppSemanticColorRGB.secondaryText, minimumRatio: 4.5),
        .init(name: "listening body", foreground: AppSemanticColorRGB.white, background: AppSemanticColorRGB.listeningBackground, minimumRatio: 4.5),
        .init(name: "listening secondary", foreground: AppSemanticColorRGB.listeningSecondary, background: AppSemanticColorRGB.listeningBackground, minimumRatio: 4.5),
        .init(name: "recording status", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.listeningBackground, minimumRatio: 4.5),
        .init(name: "playback primary action", foreground: AppSemanticColorRGB.captureText, background: AppSemanticColorRGB.listeningAccent, minimumRatio: 4.5),
        .init(name: "capture action", foreground: AppSemanticColorRGB.captureText, background: AppSemanticColorRGB.captureBackground, minimumRatio: 4.5),
        .init(name: "locked capture context", foreground: AppSemanticColorRGB.listeningBackground, background: AppSemanticColorRGB.captureBackground, minimumRatio: 4.5),
        .init(name: "body on app background", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "body on panel", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "secondary on app background", foreground: AppSemanticColorRGB.secondaryText, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "secondary on panel", foreground: AppSemanticColorRGB.secondaryText, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "primary button label", foreground: .init(light: .init(red: 1, green: 1, blue: 1), dark: .init(red: 1, green: 1, blue: 1)), background: AppSemanticColorRGB.primaryAction, minimumRatio: 4.5),
        .init(name: "response import label", foreground: AppSemanticColorRGB.onEvergreen, background: AppSemanticColorRGB.plum, minimumRatio: 4.5),
        .init(name: "label on evergreen", foreground: AppSemanticColorRGB.onEvergreen, background: AppSemanticColorRGB.evergreen, minimumRatio: 4.5),
        .init(name: "body on soft green", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "danger label", foreground: AppSemanticColorRGB.dangerText, background: AppSemanticColorRGB.dangerBackground, minimumRatio: 4.5),
        // Tokens that were defined only in the app (#1921).
        .init(name: "secondary on soft green", foreground: AppSemanticColorRGB.secondaryText, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "green text on app background", foreground: AppSemanticColorRGB.green, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "green text on panel", foreground: AppSemanticColorRGB.green, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "green text on soft green", foreground: AppSemanticColorRGB.green, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        // The selected tiles and chips draw the evergreen mark on soft green (found by the token-chain scan, #3739).
        .init(name: "evergreen on soft green", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "coral text on app background", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "coral text on panel", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "coral text on soft green", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "ochre text on bone", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "ochre text on panel", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "ochre text on soft green", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "ochre text on app background", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "warning text on panel", foreground: AppSemanticColorRGB.warningText, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "warning text on bone", foreground: AppSemanticColorRGB.warningText, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "warning text on app background", foreground: AppSemanticColorRGB.warningText, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "warning text on soft green", foreground: AppSemanticColorRGB.warningText, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "playback accent on watch control", foreground: AppSemanticColorRGB.accent, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening accent on watch control", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening secondary on watch control", foreground: AppSemanticColorRGB.listeningSecondary, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening accent on watch background", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        .init(name: "listening secondary on watch background", foreground: AppSemanticColorRGB.listeningSecondary, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        .init(name: "danger label on watch control", foreground: AppSemanticColorRGB.watchDanger, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "danger label on watch background", foreground: AppSemanticColorRGB.watchDanger, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        // The reply row's "Stop replying" and "Reply to …" buttons on the Margin writing sheet, which is bone (#3890).
        .init(name: "evergreen text on bone", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        // The follow-a-source card's two quiet buttons and its caption sit on a panel (#3732).
        .init(name: "evergreen text on panel", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "danger text on panel", foreground: AppSemanticColorRGB.dangerText, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "NOW badge label", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.accentSoft, minimumRatio: 4.5),
        // iOS draws a swipe button's icon and words in white; the tints are fixed so they hold in dark mode too (#4045).
        .init(name: "swipe label on swipeEvergreen", foreground: AppSemanticColorRGB.white, background: AppSemanticColorRGB.swipeEvergreen, minimumRatio: 4.5),
        .init(name: "swipe label on swipeOchre", foreground: AppSemanticColorRGB.white, background: AppSemanticColorRGB.swipeOchre, minimumRatio: 4.5),
        .init(name: "swipe label on swipePlum", foreground: AppSemanticColorRGB.white, background: AppSemanticColorRGB.swipePlum, minimumRatio: 4.5),
        .init(name: "swipe label on swipeSlate", foreground: AppSemanticColorRGB.white, background: AppSemanticColorRGB.swipeSlate, minimumRatio: 4.5)
    ]

    /// Icons, borders, fills and state marks need 3:1 against what they sit on (WCAG 1.4.11).
    public static let nonTextPairs: [Pair] = [
        .init(name: "evergreen icon on panel", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "evergreen icon on app background", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "plum icon on panel", foreground: AppSemanticColorRGB.plum, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "danger icon on panel", foreground: AppSemanticColorRGB.dangerText, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "green icon on panel", foreground: AppSemanticColorRGB.green, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "green icon on soft green", foreground: AppSemanticColorRGB.green, background: AppSemanticColorRGB.softGreen, minimumRatio: 3),
        .init(name: "coral icon on panel", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "coral icon on soft green", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.softGreen, minimumRatio: 3),
        .init(name: "ochre icon on bone", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.bone, minimumRatio: 3),
        // The Library row's unread dot for a friend's unheard Margins: a shape, on the row (#4698).
        .init(name: "unread dot on bone", foreground: AppSystemColorRGB.blue, background: AppSemanticColorRGB.bone, minimumRatio: 3),
        .init(name: "ochre icon on panel", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "ochre icon on soft green", foreground: AppSemanticColorRGB.ochreText, background: AppSemanticColorRGB.softGreen, minimumRatio: 3),
        .init(name: "warning icon on panel", foreground: AppSemanticColorRGB.warningText, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "star icon on panel", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "star icon on app background", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "watch star on watch background", foreground: AppSemanticColorRGB.watchStar, background: AppSemanticColorRGB.watchBackground, minimumRatio: 3),
        .init(name: "watch star on listening background", foreground: AppSemanticColorRGB.watchStar, background: AppSemanticColorRGB.listeningBackground, minimumRatio: 3),
        .init(name: "star icon on bone", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.bone, minimumRatio: 3),
        .init(name: "border on app background", foreground: AppSemanticColorRGB.border, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "border on panel", foreground: AppSemanticColorRGB.border, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "input fill on panel", foreground: AppSemanticColorRGB.inputBackground, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "input fill on app background", foreground: AppSemanticColorRGB.inputBackground, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "playback accent mark on watch control", foreground: AppSemanticColorRGB.accent, background: AppSemanticColorRGB.watchControl, minimumRatio: 3)
    ]

    /// A tint drawn at `alpha` over `base`, with the text that sits on it. The name carries the tint, its alpha and the
    /// base's name, which is how the tint guard finds the pairs that audit a tint.
    private static func onTint(
        _ label: String, foreground: AppDynamicRGB, tint: String, tintColor: AppDynamicRGB, alpha: Double,
        over base: AppDynamicRGB, baseName: String, minimumRatio: Double = 4.5
    ) -> Pair {
        Pair(
            name: "\(label) on \(tint) at \(alpha) over \(baseName)",
            foreground: foreground,
            background: tintColor.composited(over: base, alpha: alpha),
            minimumRatio: minimumRatio
        )
    }

    /// The Timeline rail's rows (`PlaybackTimelineListView.swift`), from `TimelineRowPalette`: each row is a fill over
    /// what is behind the list, and the row's own words are drawn on it (#3734). The standalone screen sits on bone and
    /// follows light and dark. The playback pane forces dark over the fixed listening plate, so its pairs are the dark
    /// values in both appearances. Every kind has a title, a detail and a label pair, and the current row (one fill for
    /// every kind) has its own set. A pair that two rows share is measured once.
    public static let timelineRowPairs: [Pair] = {
        func darkOnly(_ color: AppDynamicRGB) -> AppDynamicRGB { AppDynamicRGB(light: color.dark, dark: color.dark) }
        let labelNames: [TimelineRowKind: String] = [
            .source: "chapter row label", .listeningMap: "map row label", .myMargin: "my Margin row label",
            .userResponse: "response row label", .sharedMargin: "shared Margin row label",
            .assistantResponse: "assistant row label"
        ]
        let surfaces: [(baseName: String, base: AppDynamicRGB, map: (AppDynamicRGB) -> AppDynamicRGB)] = [
            ("bone", AppSemanticColorRGB.bone, { $0 }),
            ("listening background", AppSemanticColorRGB.listeningBackground, darkOnly)
        ]
        var seen = Set<String>()
        var pairs: [Pair] = []
        for surface in surfaces {
            var rows: [(fill: TimelineRowPalette.Fill, labelName: String, label: AppDynamicRGB)] = [
                (TimelineRowPalette.fill(kind: .source, isCurrent: true), "current row label", TimelineRowPalette.currentLabelColor)
            ]
            for kind in TimelineRowKind.allCases {
                rows.append((TimelineRowPalette.fill(kind: kind, isCurrent: false), labelNames[kind] ?? "\(kind.rawValue) row label",
                             TimelineRowPalette.labelColor(kind: kind)))
                // The current row keeps its kind's label and icon, now on the highlighted card's fill.
                rows.append((TimelineRowPalette.fill(kind: kind, isCurrent: true), labelNames[kind] ?? "\(kind.rawValue) row label",
                             TimelineRowPalette.labelColor(kind: kind)))
            }
            for row in rows {
                for (name, color) in [("row title", AppSemanticColorRGB.text), ("row detail", AppSemanticColorRGB.secondaryText),
                                      (row.labelName, row.label)] {
                    let pair = onTint(name, foreground: surface.map(color), tint: row.fill.token, tintColor: surface.map(row.fill.color),
                                      alpha: row.fill.alpha, over: surface.base, baseName: surface.baseName)
                    if seen.insert(pair.name).inserted { pairs.append(pair) }
                }
            }
        }
        // The current row's outline marks a state, so it reaches 3:1 against what is behind the list. The other rows'
        // outlines only echo the kind, which the label already says, and need no pair.
        let currentStroke = TimelineRowPalette.currentStrokeColor
        pairs.append(.init(name: "current row stroke on bone", foreground: currentStroke,
                           background: AppSemanticColorRGB.bone, minimumRatio: 3))
        pairs.append(.init(name: "current row stroke on listening background", foreground: darkOnly(currentStroke),
                           background: darkOnly(AppSemanticColorRGB.listeningBackground), minimumRatio: 3))
        return pairs
    }()

    /// The Watch's plates, from `WatchPlatePalette` (#3731): each plate's label on its fill, and on the fill as pressed,
    /// both over the Watch's black screen, and the two targets' header text on black. watchOS has one appearance, so each
    /// colour is listed once for both. Stop draws the episode or session plate, so it has no pair of its own.
    public static let watchPlatePairs: [Pair] = {
        func color(_ c: WatchPlateColor) -> AppDynamicRGB {
            let rgb = AppColorRGB(red: c.red, green: c.green, blue: c.blue)
            return AppDynamicRGB(light: rgb, dark: rgb)
        }
        let black = color(WatchPlatePalette.watchBlack)
        var pairs: [Pair] = []
        for plate in WatchPlate.allCases {
            let fill = WatchPlatePalette.fill(plate)
            let label = color(WatchPlatePalette.label(plate))
            pairs.append(.init(
                name: "watch \(plate.rawValue) plate label", foreground: label,
                background: color(fill.color).composited(over: black, alpha: fill.alpha), minimumRatio: 4.5))
            pairs.append(.init(
                name: "watch \(plate.rawValue) plate label, pressed", foreground: label,
                background: color(fill.color).composited(over: black, alpha: fill.alpha * WatchPlatePalette.pressedMultiplier),
                minimumRatio: 4.5))
        }
        for plate in [WatchPlate.episode, .session] {
            pairs.append(.init(
                name: "watch \(plate.rawValue) header text", foreground: color(WatchPlatePalette.headerText(plate)),
                background: black, minimumRatio: 4.5))
        }
        return pairs
    }()

    /// Fills that carry an icon or a label and are not Timeline rows (#3739): the round icon
    /// badges, the library row icon tiles, the selected subject chip and the live passage's current sentence. Each is a tint over the surface it is
    /// drawn on (the badges sit in a panel card, the row tiles and chips on bone), and the mark on it is read as an icon (3:1) or as text (4.5:1).
    public static let tintedFillPairs: [Pair] = [
        onTint("round icon badge", foreground: AppSemanticColorRGB.ochreText, tint: "ochre", tintColor: AppSemanticColorRGB.ochre, alpha: 0.12, over: AppSemanticColorRGB.panel, baseName: "panel", minimumRatio: 3),
        onTint("library row icon", foreground: AppSemanticColorRGB.evergreen, tint: "softGreen", tintColor: AppSemanticColorRGB.softGreen, alpha: 0.85, over: AppSemanticColorRGB.bone, baseName: "bone", minimumRatio: 3),
        onTint("library row icon", foreground: AppSemanticColorRGB.evergreen, tint: "softGreen", tintColor: AppSemanticColorRGB.softGreen, alpha: 0.55, over: AppSemanticColorRGB.bone, baseName: "bone", minimumRatio: 3),
        onTint("selected chip label", foreground: AppSemanticColorRGB.text, tint: "evergreen", tintColor: AppSemanticColorRGB.evergreen, alpha: 0.16, over: AppSemanticColorRGB.bone, baseName: "bone"),
        onTint("current sentence text", foreground: AppSemanticColorRGB.white, tint: "listeningAccent", tintColor: AppSemanticColorRGB.listeningAccent, alpha: 0.18, over: AppSemanticColorRGB.listeningBackground, baseName: "listening background")
    ]

    /// The playback plate's two segmented controls (#3735): the tray over the listening plate, the selected pill over
    /// the tray, and the words on each. The pill must read against the tray (3:1) and its words against the pill (4.5:1).
    public static let playbackSegmentPairs: [Pair] = [
        .init(name: "pane switch selected fill against tray", foreground: PlaybackSegmentPalette.paneSelectedPill,
              background: PlaybackSegmentPalette.tray, minimumRatio: 3),
        .init(name: "pane switch selected label", foreground: PlaybackSegmentPalette.selectedLabel,
              background: PlaybackSegmentPalette.paneSelectedPill, minimumRatio: 4.5),
        .init(name: "filter selected fill against tray", foreground: PlaybackSegmentPalette.filterSelectedPill,
              background: PlaybackSegmentPalette.tray, minimumRatio: 3),
        .init(name: "filter selected label", foreground: PlaybackSegmentPalette.selectedLabel,
              background: PlaybackSegmentPalette.filterSelectedPill, minimumRatio: 4.5),
        .init(name: "segment unselected label on tray", foreground: PlaybackSegmentPalette.unselectedLabel,
              background: PlaybackSegmentPalette.tray, minimumRatio: 4.5),
        .init(name: "segment selected bar on pill", foreground: PlaybackSegmentPalette.selectedLabel,
              background: PlaybackSegmentPalette.paneSelectedPill, minimumRatio: 3)
    ]

    /// The app's one tint (#3733). `evergreen` is the asset catalog's global accent and the root `.tint`, so every
    /// default-tinted link, bordered button label, toggle and dialog button is drawn in it, on bone, the panel, the soft
    /// green and the app background. A system `.bordered` button draws that label over a tint of the same colour; 0.25 is an
    /// assumed upper bound for the system's fill, not a measured value. The default-tinted controls on the always-dark
    /// listening plate take `listeningAccent` instead.
    public static let accentPairs: [Pair] = [
        .init(name: "app accent text on bone", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "app accent text on panel", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "app accent text on soft green", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "app accent text on app background", foreground: AppSemanticColorRGB.evergreen, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        onTint("bordered button label", foreground: AppSemanticColorRGB.evergreen, tint: "app accent", tintColor: AppSemanticColorRGB.evergreen, alpha: 0.25, over: AppSemanticColorRGB.bone, baseName: "bone"),
        onTint("bordered button label", foreground: AppSemanticColorRGB.evergreen, tint: "app accent", tintColor: AppSemanticColorRGB.evergreen, alpha: 0.25, over: AppSemanticColorRGB.panel, baseName: "panel"),
        .init(name: "plate accent on listening background", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.listeningBackground, minimumRatio: 4.5)
    ]

    /// The Source Text reader's current-sentence mark (#3736): a fill and a thick underline over the reader's surface
    /// (`inputBackground`), from `ReaderSentenceHighlight`. The words are read on the fill (4.5:1); the underline is a
    /// mark, so 3:1 against the page and against the fill it runs through.
    public static let readerHighlightPairs: [Pair] = {
        let fill = ReaderSentenceHighlight.fill
        let alpha = ReaderSentenceHighlight.fillAlpha
        let page = AppSemanticColorRGB.inputBackground
        let composited = fill.composited(over: page, alpha: alpha)
        return [
            .init(name: "reader text on current sentence fill", foreground: AppSystemColorRGB.label, background: composited, minimumRatio: 4.5),
            .init(name: "reader sentence underline on reader surface", foreground: ReaderSentenceHighlight.underline, background: page, minimumRatio: 3),
            .init(name: "reader sentence underline on its fill", foreground: ReaderSentenceHighlight.underline, background: composited, minimumRatio: 3)
        ]
    }()

    /// The button and card fills drawn at a lower alpha, which is how a pressed state or a dimmed card is drawn (#3739):
    /// each is read as the fill over the surface it sits on, with the label the button draws. The pressed state is the
    /// alpha, so a button label has to hold up on the dimmed fill too. The playback screen is always dark, so its
    /// buttons sit on the listening background; the light buttons sit on bone or on the app background.
    public static let pressedFillPairs: [Pair] = {
        let listening = (color: AppSemanticColorRGB.listeningBackground, name: "listening background")
        let light = [(color: AppSemanticColorRGB.bone, name: "bone"), (color: AppSemanticColorRGB.background, name: "app background")]
        var pairs: [Pair] = []
        // The Listening options card and the on-device generation card: white and the dim listening grey on the plate.
        for alpha in [0.72, 0.8] {
            pairs.append(onTint("plate label", foreground: AppSemanticColorRGB.white, tint: "watchControl", tintColor: AppSemanticColorRGB.watchControl, alpha: alpha, over: listening.color, baseName: listening.name))
            pairs.append(onTint("plate caption", foreground: AppSemanticColorRGB.listeningSecondary, tint: "watchControl", tintColor: AppSemanticColorRGB.watchControl, alpha: alpha, over: listening.color, baseName: listening.name))
        }
        // The on-device voice card (0.8) also draws the accent for its icons and spinner, and a Stop button tinted `watchDanger`.
        pairs.append(onTint("voice card icon", foreground: AppSemanticColorRGB.accent, tint: "watchControl", tintColor: AppSemanticColorRGB.watchControl, alpha: 0.8, over: listening.color, baseName: listening.name, minimumRatio: 3))
        pairs.append(onTint("voice card Stop label", foreground: AppSemanticColorRGB.watchDanger, tint: "watchControl", tintColor: AppSemanticColorRGB.watchControl, alpha: 0.8, over: listening.color, baseName: listening.name))
        pairs.append(onTint("main play icon", foreground: AppSemanticColorRGB.captureText, tint: "listeningAccent", tintColor: AppSemanticColorRGB.listeningAccent, alpha: 0.75, over: listening.color, baseName: listening.name, minimumRatio: 3))
        pairs.append(onTint("Add a Margin label", foreground: AppSemanticColorRGB.captureText, tint: "captureBackground", tintColor: AppSemanticColorRGB.captureBackground, alpha: 0.78, over: listening.color, baseName: listening.name))
        for base in light {
            pairs.append(onTint("light button label", foreground: AppSemanticColorRGB.text, tint: "panel", tintColor: AppSemanticColorRGB.panel, alpha: 0.75, over: base.color, baseName: base.name))
            pairs.append(onTint("primary button label", foreground: AppSemanticColorRGB.white, tint: "primaryAction", tintColor: AppSemanticColorRGB.primaryAction, alpha: 0.78, over: base.color, baseName: base.name))
            pairs.append(onTint("secondary button label", foreground: AppSemanticColorRGB.text, tint: "softGreen", tintColor: AppSemanticColorRGB.softGreen, alpha: 0.7, over: base.color, baseName: base.name))
        }
        return pairs
    }()

    /// The Live Activity (`Gate2LiveActivityWidget.swift`, `LiveSessionActivityWidget.swift`): white text at several alphas, the
    /// progress blue, red and orange marks, and the chips, all on the fixed dark plate (#3739 slice 3). White at an alpha is a tint,
    /// so each is composited over the plate; a chip is white or green at an alpha over the plate with white text on it.
    public static let liveActivityPairs: [Pair] = {
        let plate = AppSystemColorRGB.liveActivityPlate
        let white = AppSemanticColorRGB.white
        var pairs: [Pair] = [
            .init(name: "live activity title", foreground: white, background: plate, minimumRatio: 4.5),
            .init(name: "live activity progress mark", foreground: AppSystemColorRGB.liveActivityProgress, background: plate, minimumRatio: 3),
            // The state words are bold caption text (`recordingTint`), so they need the text ratio.
            .init(name: "live activity recording state text (red)", foreground: AppSystemColorRGB.liveActivityRed, background: plate, minimumRatio: 4.5),
            .init(name: "live activity paused state text (orange)", foreground: AppSystemColorRGB.liveActivityOrange, background: plate, minimumRatio: 4.5),
            // The headline buttons of the live session card (Resume, Mark, Finish Margin) are tinted with the progress blue, a fixed
            // literal, not the system blue that resolved to its 4.46:1 light value on the plate (#3739). Their label is text too.
            .init(name: "live activity button label tint (progress blue)", foreground: AppSystemColorRGB.liveActivityProgress, background: plate, minimumRatio: 4.5),
            // The Dynamic Island's `Next:` line is `.secondary` on its black.
            .init(
                name: "dynamic island secondary text",
                foreground: AppSystemColorRGB.darkSecondaryLabel.composited(over: AppSystemColorRGB.dynamicIslandBlack, alpha: 0.6),
                background: AppSystemColorRGB.dynamicIslandBlack, minimumRatio: 4.5
            )
        ]
        for alpha in [0.74, 0.78, 0.8, 0.84, 0.86] {
            pairs.append(.init(name: "live activity white text at \(alpha)", foreground: white.composited(over: plate, alpha: alpha), background: plate, minimumRatio: 4.5))
        }
        let chips: [(String, AppDynamicRGB, Double)] = [
            ("white", white, 0.16), ("white", white, 0.12), ("white", white, 0.14),
            ("green", AppSystemColorRGB.liveActivityGreenSystem, 0.28), ("green (literal)", AppSystemColorRGB.liveActivityGreen, 0.28)
        ]
        for chip in chips {
            pairs.append(onTint("live activity chip label", foreground: white, tint: chip.0, tintColor: chip.1, alpha: chip.2, over: plate, baseName: "live activity plate"))
        }
        pairs.append(.init(
            name: "live activity chip label at 0.86 on white at 0.12 over live activity plate",
            foreground: white.composited(over: plate, alpha: 0.86),
            background: white.composited(over: plate, alpha: 0.12),
            minimumRatio: 4.5
        ))
        // The Lock Screen card's start-Margin circle: a ring of white at 0.86 on its own fill of white at 0.16. It is a
        // control edge, not text, so it needs the non-text ratio; it keeps the circle visible on a dimmed screen (#4764).
        pairs.append(.init(
            name: "live activity Margin ring at 0.86 on white at 0.16 over live activity plate",
            foreground: white.composited(over: plate, alpha: 0.86),
            background: white.composited(over: plate, alpha: 0.16),
            minimumRatio: 3
        ))
        return pairs
    }()

    /// The share extension's status card (`SourceLinkShareViewController.swift`): UIKit's `label` on `secondarySystemBackground`, with
    /// the app's `green` for the icon and the Done button. The extension doesn't link SessionKit, so it carries a copy of the
    /// green; the guard tests keep the copy equal to the token (#3739 slice 4).
    public static let shareExtensionPairs: [Pair] = [
        .init(name: "share extension title", foreground: AppSystemColorRGB.label, background: AppSystemColorRGB.secondarySystemBackground, minimumRatio: 4.5),
        .init(name: "share extension status line", foreground: AppSystemColorRGB.label, background: AppSystemColorRGB.secondarySystemBackground, minimumRatio: 4.5),
        .init(name: "share extension Done label (app green)", foreground: AppSemanticColorRGB.green, background: AppSystemColorRGB.secondarySystemBackground, minimumRatio: 4.5),
        .init(name: "share extension icon (app green)", foreground: AppSemanticColorRGB.green, background: AppSystemColorRGB.secondarySystemBackground, minimumRatio: 3)
    ]

    /// The Safari popup (`popup.css`): every colour is a fixed hex on one dark plate. The disabled button is the whole
    /// button at 55% over the plate; a disabled control is exempt from WCAG 1.4.3, and it is held to 3:1 here so it stays
    /// legible as a control.
    public static let safariPopupPairs: [Pair] = {
        let plate = AppSafariPopupRGB.plate
        return [
            .init(name: "safari popup body and title", foreground: AppSafariPopupRGB.text, background: plate, minimumRatio: 4.5),
            .init(name: "safari popup brand mark", foreground: AppSafariPopupRGB.markText, background: AppSafariPopupRGB.accent, minimumRatio: 4.5),
            .init(name: "safari popup caption", foreground: AppSafariPopupRGB.caption, background: plate, minimumRatio: 4.5),
            .init(name: "safari popup button label", foreground: AppSafariPopupRGB.buttonText, background: AppSafariPopupRGB.accent, minimumRatio: 4.5),
            .init(
                name: "safari popup disabled button label (exempt, kept above 3:1)",
                foreground: AppSafariPopupRGB.buttonText.composited(over: plate, alpha: 0.55),
                background: AppSafariPopupRGB.accent.composited(over: plate, alpha: 0.55), minimumRatio: 3
            ),
            .init(name: "safari popup status line", foreground: AppSafariPopupRGB.status, background: plate, minimumRatio: 4.5)
        ]
    }()

    public static var allPairs: [Pair] {
        textBackgroundPairs + nonTextPairs + increasedContrastEdgePairs + timelineRowPairs + watchPlatePairs + tintedFillPairs + accentPairs + readerHighlightPairs + pressedFillPairs + liveActivityPairs
            + shareExtensionPairs + safariPopupPairs + playbackSegmentPairs
    }

    /// A pair that fails today, in an appearance, with the issue that fixes it. The audit prints these
    /// instead of hiding them, and fails when one starts to pass so the entry gets removed (#1921).
    public struct KnownFailure: Equatable, Sendable {
        public let pair: String
        public let appearance: String
        public let since: String
        public let fixedBy: String
    }

    public static let knownFailures: [KnownFailure] = [
        .init(pair: "border on app background", appearance: "light", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "border on app background", appearance: "dark", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "border on panel", appearance: "light", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "border on panel", appearance: "dark", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "input fill on panel", appearance: "light", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "input fill on panel", appearance: "dark", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "input fill on app background", appearance: "light", since: "2026-10-17", fixedBy: "#1922"),
        .init(pair: "input fill on app background", appearance: "dark", since: "2026-10-17", fixedBy: "#1922")
    ]


    public struct Measurement: Equatable, Sendable {
        public let pair: String
        public let appearance: String
        public let ratio: Double
        public let minimumRatio: Double

        public var fails: Bool { ratio + 0.000_001 < minimumRatio }
        public var description: String { "\(pair) [\(appearance)] \(String(format: "%.2f", ratio)):1" }
    }

    /// Edges that must reach 3:1 against their surface under Increase Contrast (#1922).
    public static let increasedContrastEdgePairs: [Pair] = [
        .init(name: "increased border on panel", foreground: AppSemanticColorRGB.borderIncreased, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "increased border on app background", foreground: AppSemanticColorRGB.borderIncreased, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "increased border on soft green", foreground: AppSemanticColorRGB.borderIncreased, background: AppSemanticColorRGB.softGreen, minimumRatio: 3)
    ]

    public static func contrastRatio(foreground: AppColorRGB, background: AppColorRGB) -> Double {
        let lighter = max(foreground.relativeLuminance, background.relativeLuminance)
        let darker = min(foreground.relativeLuminance, background.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func measurements(for pairs: [Pair]) -> [Measurement] {
        pairs.flatMap { pair in
            [
                Measurement(
                    pair: pair.name, appearance: "light",
                    ratio: contrastRatio(foreground: pair.foreground.light, background: pair.background.light),
                    minimumRatio: pair.minimumRatio
                ),
                Measurement(
                    pair: pair.name, appearance: "dark",
                    ratio: contrastRatio(foreground: pair.foreground.dark, background: pair.background.dark),
                    minimumRatio: pair.minimumRatio
                )
            ]
        }
    }

    /// Failures that are not on the known list: what a test must see empty.
    public static func failures() -> [String] {
        measurements(for: allPairs)
            .filter { measurement in
                measurement.fails && !knownFailures.contains { $0.pair == measurement.pair && $0.appearance == measurement.appearance }
            }
            .map(\.description)
    }

    public static func failures(for pairs: [Pair]) -> [String] {
        measurements(for: pairs).filter(\.fails).map(\.description)
    }

    /// One line per known failure, with its date and the issue that fixes it, for a test to print.
    public static func knownFailureReport() -> [String] {
        let measured = measurements(for: allPairs)
        return knownFailures.map { known in
            let ratio = measured.first { $0.pair == known.pair && $0.appearance == known.appearance }
                .map { String(format: "%.2f", $0.ratio) } ?? "unmeasured"
            return "known failure since \(known.since), fixed by \(known.fixedBy): \(known.pair) [\(known.appearance)] \(ratio):1"
        }
    }

    /// Known failures that no longer fail, or name a pair that does not exist: entries to delete.
    public static func staleKnownFailures() -> [KnownFailure] {
        let measured = measurements(for: allPairs)
        return knownFailures.filter { known in
            guard let measurement = measured.first(where: { $0.pair == known.pair && $0.appearance == known.appearance }) else { return true }
            return !measurement.fails
        }
    }
}
