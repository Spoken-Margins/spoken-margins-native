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
    /// A destructive label on the always-dark playback cards (Stop on-device generation): the dark-mode danger
    /// text in both appearances, since the card does not change with the system appearance (#1925).
    public static let watchDanger = fixed(1, 0.55, 0.48)

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
        ("watchBackground", watchBackground), ("watchControl", watchControl), ("ochre", ochre), ("coral", coral),
        ("star", star), ("watchDanger", watchDanger)
    ]
}

/// iOS system colours the app still draws with, as the approximate values Apple publishes. They move a little
/// between releases, so a ratio here is "about", and a pair using one is a warning sign, not a proof.
public enum AppSystemColorApproximation {
    public static let orange = AppDynamicRGB(
        light: .init(red: 1.0, green: 0.584, blue: 0.0),
        dark: .init(red: 1.0, green: 0.624, blue: 0.039)
    )
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
        .init(name: "coral text on app background", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.background, minimumRatio: 4.5),
        .init(name: "coral text on panel", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "coral text on soft green", foreground: AppSemanticColorRGB.coral, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "ochre text on bone", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "ochre text on panel", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "ochre text on soft green", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.softGreen, minimumRatio: 4.5),
        .init(name: "system orange text on panel", foreground: AppSystemColorApproximation.orange, background: AppSemanticColorRGB.panel, minimumRatio: 4.5),
        .init(name: "system orange text on bone", foreground: AppSystemColorApproximation.orange, background: AppSemanticColorRGB.bone, minimumRatio: 4.5),
        .init(name: "playback accent on watch control", foreground: AppSemanticColorRGB.accent, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening accent on watch control", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening secondary on watch control", foreground: AppSemanticColorRGB.listeningSecondary, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "listening accent on watch background", foreground: AppSemanticColorRGB.listeningAccent, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        .init(name: "listening secondary on watch background", foreground: AppSemanticColorRGB.listeningSecondary, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        .init(name: "danger label on watch control", foreground: AppSemanticColorRGB.watchDanger, background: AppSemanticColorRGB.watchControl, minimumRatio: 4.5),
        .init(name: "danger label on watch background", foreground: AppSemanticColorRGB.watchDanger, background: AppSemanticColorRGB.watchBackground, minimumRatio: 4.5),
        .init(name: "NOW badge label", foreground: AppSemanticColorRGB.text, background: AppSemanticColorRGB.accentSoft, minimumRatio: 4.5)
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
        .init(name: "ochre icon on bone", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.bone, minimumRatio: 3),
        .init(name: "ochre icon on panel", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "ochre icon on soft green", foreground: AppSemanticColorRGB.ochre, background: AppSemanticColorRGB.softGreen, minimumRatio: 3),
        .init(name: "system orange icon on panel", foreground: AppSystemColorApproximation.orange, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "star icon on panel", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "star icon on app background", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "star icon on bone", foreground: AppSemanticColorRGB.star, background: AppSemanticColorRGB.bone, minimumRatio: 3),
        .init(name: "border on app background", foreground: AppSemanticColorRGB.border, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "border on panel", foreground: AppSemanticColorRGB.border, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "input fill on panel", foreground: AppSemanticColorRGB.inputBackground, background: AppSemanticColorRGB.panel, minimumRatio: 3),
        .init(name: "input fill on app background", foreground: AppSemanticColorRGB.inputBackground, background: AppSemanticColorRGB.background, minimumRatio: 3),
        .init(name: "playback accent mark on watch control", foreground: AppSemanticColorRGB.accent, background: AppSemanticColorRGB.watchControl, minimumRatio: 3)
    ]

    public static var allPairs: [Pair] { textBackgroundPairs + nonTextPairs + increasedContrastEdgePairs }

    /// A pair that fails today, in an appearance, with the issue that fixes it. The audit prints these
    /// instead of hiding them, and fails when one starts to pass so the entry gets removed (#1921).
    public struct KnownFailure: Equatable, Sendable {
        public let pair: String
        public let appearance: String
        public let since: String
        public let fixedBy: String
    }

    public static let knownFailures: [KnownFailure] = [
        .init(pair: "ochre text on bone", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "ochre text on panel", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "ochre text on soft green", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "system orange text on panel", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "system orange text on bone", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "ochre icon on bone", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "ochre icon on soft green", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
        .init(pair: "system orange icon on panel", appearance: "light", since: "2026-10-17", fixedBy: "#1920"),
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
