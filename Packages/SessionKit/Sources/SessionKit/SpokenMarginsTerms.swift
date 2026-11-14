import Foundation

/// The Terms of Use the listener accepts before an on-device voice is enabled: the current version, where
/// the acceptance is stored, and the public links. It lives here so the acceptance rules run on the host (#318).
/// The bundled text is read from the app's resources, so `bundledText` stays in the app
/// (`SpokenMarginsTerms+BundledText.swift`).
public enum SpokenMarginsTerms {
    public static let currentVersion = "1.0"
    public static let effectiveDate = "July 23, 2026"
    public static let acceptanceVersionKey = "spokenMarginsTermsAcceptedVersion"
    public static let acceptanceDateKey = "spokenMarginsTermsAcceptedAt"

    public static let publicURL = URL(string: "https://spokenmargins.proximitytoprogress.com/terms/")!
    public static let appleStandardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    public static func acceptedVersion(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: acceptanceVersionKey)
    }

    public static func acceptedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: acceptanceDateKey) as? Date
    }

    public static func hasAcceptedCurrentVersion(in defaults: UserDefaults = .standard) -> Bool {
        acceptedVersion(in: defaults) == currentVersion
    }

    public static func recordAcceptance(
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(currentVersion, forKey: acceptanceVersionKey)
        defaults.set(date, forKey: acceptanceDateKey)
    }

    public static func clearAcceptance(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: acceptanceVersionKey)
        defaults.removeObject(forKey: acceptanceDateKey)
    }
}

public enum SpokenMarginsTermsError: LocalizedError, Equatable {
    case acceptanceRequired
    case bundledTermsUnavailable

    public var errorDescription: String? {
        switch self {
        case .acceptanceRequired:
            return "Accept the current Spoken Margins Terms of Use before enabling an on-device voice."
        case .bundledTermsUnavailable:
            return "The bundled Spoken Margins Terms of Use are unavailable. The on-device voice remains disabled."
        }
    }
}
