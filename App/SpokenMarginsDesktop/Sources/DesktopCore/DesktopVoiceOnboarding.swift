import Foundation

public enum DesktopVoiceBackend: String, CaseIterable, Sendable {
    case mac
    case supertonic
    case chatterbox

    public var title: String {
        switch self {
        case .mac: "Mac voices"
        case .supertonic: "Supertonic"
        case .chatterbox: "Chatterbox"
        }
    }
}

public enum DesktopChatterboxModel: String, CaseIterable, Sendable {
    case nano
    case turbo

    public var title: String {
        self == .nano ? "Nano (recommended, lower memory)" : "Turbo (higher quality, higher memory)"
    }

    public var shortTitle: String {
        self == .nano ? "Nano" : "Turbo"
    }
}

/// An acceptance is tied to the exact notice revision shown during onboarding.
/// Changing a notice revision requires a new explicit acceptance.
public enum DesktopVoiceTerms {
    public static let supertonicRevision = "supertonic-code-mit-model-openrail-m-2026-09"
    public static let chatterboxRevision = "chatterbox-code-model-mit-2026-09"

    public static func revision(for backend: DesktopVoiceBackend, variant: DesktopChatterboxModel = .nano) -> String? {
        switch backend {
        case .mac: nil
        case .supertonic: supertonicRevision
        case .chatterbox: chatterboxRevision + "-" + variant.rawValue
        }
    }

    public static func hasAccepted(_ backend: DesktopVoiceBackend, variant: DesktopChatterboxModel = .nano,
                                   defaults: UserDefaults = .standard) -> Bool {
        guard let revision = revision(for: backend, variant: variant) else { return true }
        return defaults.string(forKey: acceptanceKey(for: backend, variant: variant)) == revision
    }

    public static func accept(_ backend: DesktopVoiceBackend, variant: DesktopChatterboxModel = .nano,
                              defaults: UserDefaults = .standard) {
        guard let revision = revision(for: backend, variant: variant) else { return }
        defaults.set(revision, forKey: acceptanceKey(for: backend, variant: variant))
        defaults.set(Date(), forKey: acceptanceDateKey(for: backend, variant: variant))
    }

    private static func acceptanceKey(for backend: DesktopVoiceBackend,
                                      variant: DesktopChatterboxModel) -> String {
        backend == .chatterbox
            ? "desktopVoiceTerms.chatterbox.\(variant.rawValue)"
            : "desktopVoiceTerms.\(backend.rawValue)"
    }

    private static func acceptanceDateKey(for backend: DesktopVoiceBackend,
                                          variant: DesktopChatterboxModel) -> String {
        backend == .chatterbox
            ? "desktopVoiceTermsDate.chatterbox.\(variant.rawValue)"
            : "desktopVoiceTermsDate.\(backend.rawValue)"
    }
}
