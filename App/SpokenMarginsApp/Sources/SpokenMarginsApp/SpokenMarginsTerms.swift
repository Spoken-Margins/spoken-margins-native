import Foundation

enum SpokenMarginsTerms {
    static let currentVersion = "1.0"
    static let effectiveDate = "July 23, 2026"
    static let acceptanceVersionKey = "spokenMarginsTermsAcceptedVersion"
    static let acceptanceDateKey = "spokenMarginsTermsAcceptedAt"

    static let publicURL = URL(string: "https://spokenmargins.proximitytoprogress.com/terms/")!
    static let appleStandardEULAURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static func acceptedVersion(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: acceptanceVersionKey)
    }

    static func acceptedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: acceptanceDateKey) as? Date
    }

    static func hasAcceptedCurrentVersion(in defaults: UserDefaults = .standard) -> Bool {
        acceptedVersion(in: defaults) == currentVersion
    }

    static func recordAcceptance(
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(currentVersion, forKey: acceptanceVersionKey)
        defaults.set(date, forKey: acceptanceDateKey)
    }

    static func clearAcceptance(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: acceptanceVersionKey)
        defaults.removeObject(forKey: acceptanceDateKey)
    }

    static func hasBundledText(in bundle: Bundle = .main) -> Bool {
        bundle.url(
            forResource: "SPOKEN_MARGINS_TERMS_OF_USE",
            withExtension: "txt",
            subdirectory: "Legal"
        ) != nil
    }

    static func bundledText(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(
            forResource: "SPOKEN_MARGINS_TERMS_OF_USE",
            withExtension: "txt",
            subdirectory: "Legal"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled Spoken Margins Terms of Use are unavailable. On-device voice remains disabled."
        }
        return text
    }
}

enum SpokenMarginsTermsError: LocalizedError, Equatable {
    case acceptanceRequired
    case bundledTermsUnavailable

    var errorDescription: String? {
        switch self {
        case .acceptanceRequired:
            return "Accept the current Spoken Margins Terms of Use before enabling an on-device voice."
        case .bundledTermsUnavailable:
            return "The bundled Spoken Margins Terms of Use are unavailable. The on-device voice remains disabled."
        }
    }
}
