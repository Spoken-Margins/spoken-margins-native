import Foundation

public struct DesktopVoiceDescriptor: Equatable, Sendable {
    public let id: String
    public let language: String

    public init(id: String, language: String) {
        self.id = id
        self.language = language.replacingOccurrences(of: "_", with: "-")
    }
}

public enum DesktopVoiceCatalog {
    public static func languageCode(for identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    }

    public static func languages(for voices: [DesktopVoiceDescriptor]) -> [String] {
        Array(Set(voices.map { languageCode(for: $0.language) }.filter { !$0.isEmpty })).sorted {
            (Locale.current.localizedString(forLanguageCode: $0) ?? $0)
                < (Locale.current.localizedString(forLanguageCode: $1) ?? $1)
        }
    }

    public static func voices(in language: String, from voices: [DesktopVoiceDescriptor]) -> [DesktopVoiceDescriptor] {
        let code = languageCode(for: language)
        return voices.filter { languageCode(for: $0.language) == code }
    }

    public static func preferredLanguage(
        from voices: [DesktopVoiceDescriptor],
        preferredLanguages: [String]
    ) -> String? {
        let available = languages(for: voices)
        for preferred in preferredLanguages {
            let code = languageCode(for: preferred)
            if available.contains(code) {
                return code
            }
        }
        return available.first
    }
}
