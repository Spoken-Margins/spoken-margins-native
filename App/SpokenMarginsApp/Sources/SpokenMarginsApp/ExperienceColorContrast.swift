import Foundation

struct AppColorRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    fileprivate var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

struct AppDynamicRGB: Equatable, Sendable {
    let light: AppColorRGB
    let dark: AppColorRGB
}

enum AppSemanticColorRGB {
    private static func fixed(_ red: Double, _ green: Double, _ blue: Double) -> AppDynamicRGB {
        let color = AppColorRGB(red: red, green: green, blue: blue)
        return AppDynamicRGB(light: color, dark: color)
    }

    static let listeningBackground = fixed(0.09, 0.224, 0.184)
    static let captureBackground = fixed(1, 0.941, 0.745)
    static let listeningAccent = fixed(0.859, 0.929, 0.553)
    static let listeningSecondary = fixed(0.69, 0.75, 0.70)
    static let captureText = fixed(0.08, 0.10, 0.08)
    static let white = fixed(1, 1, 1)
    static let bone = AppDynamicRGB(
        light: .init(red: 0.97, green: 0.95, blue: 0.89),
        dark: .init(red: 0.08, green: 0.10, blue: 0.09)
    )
    static let background = AppDynamicRGB(
        light: .init(red: 0.96, green: 0.97, blue: 0.94),
        dark: .init(red: 0.07, green: 0.09, blue: 0.08)
    )
    static let panel = AppDynamicRGB(
        light: .init(red: 1, green: 1, blue: 1),
        dark: .init(red: 0.13, green: 0.16, blue: 0.14)
    )
    static let text = AppDynamicRGB(
        light: .init(red: 0.09, green: 0.13, blue: 0.11),
        dark: .init(red: 0.92, green: 0.95, blue: 0.91)
    )
    static let secondaryText = AppDynamicRGB(
        light: .init(red: 0.38, green: 0.44, blue: 0.41),
        dark: .init(red: 0.66, green: 0.72, blue: 0.68)
    )
    static let primaryAction = AppDynamicRGB(
        light: .init(red: 0.08, green: 0.32, blue: 0.22),
        dark: .init(red: 0.12, green: 0.36, blue: 0.23)
    )
    static let plum = AppDynamicRGB(
        light: .init(red: 0.39, green: 0.24, blue: 0.48),
        dark: .init(red: 0.78, green: 0.62, blue: 0.88)
    )
    static let evergreen = AppDynamicRGB(
        light: .init(red: 0.08, green: 0.30, blue: 0.21),
        dark: .init(red: 0.48, green: 0.84, blue: 0.62)
    )
    static let onEvergreen = AppDynamicRGB(
        light: .init(red: 1, green: 1, blue: 1),
        dark: .init(red: 0.07, green: 0.09, blue: 0.08)
    )
    static let softGreen = AppDynamicRGB(
        light: .init(red: 0.91, green: 0.94, blue: 0.88),
        dark: .init(red: 0.18, green: 0.25, blue: 0.20)
    )
    static let dangerText = AppDynamicRGB(
        light: .init(red: 0.55, green: 0.13, blue: 0.11),
        dark: .init(red: 1, green: 0.55, blue: 0.48)
    )
    static let dangerBackground = AppDynamicRGB(
        light: .init(red: 0.96, green: 0.88, blue: 0.86),
        dark: .init(red: 0.34, green: 0.15, blue: 0.13)
    )
}

enum AppColorContrastAudit {
    struct Pair: Equatable, Sendable {
        let name: String
        let foreground: AppDynamicRGB
        let background: AppDynamicRGB
        let minimumRatio: Double
    }

    static let textBackgroundPairs: [Pair] = [
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
        .init(name: "danger label", foreground: AppSemanticColorRGB.dangerText, background: AppSemanticColorRGB.dangerBackground, minimumRatio: 4.5)
    ]

    static func contrastRatio(foreground: AppColorRGB, background: AppColorRGB) -> Double {
        let lighter = max(foreground.relativeLuminance, background.relativeLuminance)
        let darker = min(foreground.relativeLuminance, background.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func failures() -> [String] {
        textBackgroundPairs.flatMap { pair in
            [
                ("light", contrastRatio(foreground: pair.foreground.light, background: pair.background.light)),
                ("dark", contrastRatio(foreground: pair.foreground.dark, background: pair.background.dark))
            ].compactMap { appearance, ratio in
                ratio + 0.000_001 < pair.minimumRatio
                    ? "\(pair.name) [\(appearance)] \(String(format: "%.2f", ratio)):1"
                    : nil
            }
        }
    }
}
