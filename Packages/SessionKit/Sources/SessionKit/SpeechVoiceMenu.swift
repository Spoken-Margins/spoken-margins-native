import Foundation

/// #4020: how Settings names and orders the iOS voices. The Speech Voice row shows `valueText`; the page behind it shows
/// `sections`. The app maps `SpeechVoiceChoice` to `Voice` (SessionKit can't see it); the quality stays the app's string.
///
/// Rules (the Design on #4020): the row's value is one short name and never a joined `name · language · quality` string;
/// the language is the section header, so no row repeats it; the quality follows the name in the row's value only when
/// two voices share a name and a language.
public struct SpeechVoiceMenu: Equatable, Sendable {
    public struct Voice: Equatable, Sendable {
        public let id: String
        public let name: String
        public let language: String
        public let quality: String

        public init(id: String, name: String, language: String, quality: String) {
            self.id = id
            self.name = name
            self.language = language
            self.quality = quality
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let quality: String
        public let isChosen: Bool
    }

    public struct Section: Equatable, Sendable, Identifiable {
        /// The language code as the voices carry it (`en-US`).
        public let id: String
        /// The language's name in the listener's own language (`English (United States)`), or the raw code when
        /// there is none.
        public let header: String
        public let rows: [Row]
    }

    public static let systemVoiceName = "System voice"
    public static let notInstalledName = "Not installed"

    /// What the Settings row shows on the right.
    public let valueText: String
    /// One section per language, the iPhone's language first. Empty when the voice list is empty.
    public let sections: [Section]
    /// True when nothing is chosen: the System voice row carries the checkmark.
    public let systemVoiceIsChosen: Bool
    /// True when a voice is chosen, the list is loaded, and the list doesn't hold it. An empty list never says this:
    /// playback also treats an empty list as "can't tell".
    public let isMissing: Bool

    /// - Parameters:
    ///   - chosenIdentifier: the saved voice identifier, `""` for the System voice.
    ///   - preferredLanguage: the iPhone's own language (`Locale.preferredLanguages.first`).
    ///   - locale: names the language headers.
    public init(voices: [Voice], chosenIdentifier: String, preferredLanguage: String?, locale: Locale = .current) {
        systemVoiceIsChosen = chosenIdentifier.isEmpty
        let chosen = chosenIdentifier.isEmpty ? nil : voices.first { $0.id == chosenIdentifier }
        isMissing = !chosenIdentifier.isEmpty && !voices.isEmpty && chosen == nil

        if chosenIdentifier.isEmpty {
            valueText = Self.systemVoiceName
        } else if let chosen {
            let sharesName = voices.contains { $0.id != chosen.id && $0.name == chosen.name && $0.language == chosen.language }
            valueText = sharesName ? "\(chosen.name) (\(chosen.quality))" : chosen.name
        } else if voices.isEmpty {
            valueText = Self.nameFromIdentifier(chosenIdentifier)
        } else {
            valueText = Self.notInstalledName
        }

        let preferred = Self.normalized(preferredLanguage)
        let preferredCode = Self.languageCode(preferred)
        let grouped = Dictionary(grouping: voices, by: \.language)
        sections = grouped.map { language, members in
            Section(
                id: language,
                header: locale.localizedString(forIdentifier: language) ?? language,
                rows: members
                    .sorted(by: Self.rowOrder)
                    .map { Row(id: $0.id, name: $0.name, quality: $0.quality, isChosen: $0.id == chosenIdentifier) })
        }.sorted { lhs, rhs in
            func rank(_ section: Section) -> Int {
                let language = Self.normalized(section.id)
                if let preferred, language == preferred { return 0 }
                if let preferredCode, Self.languageCode(language) == preferredCode { return 1 }
                return 2
            }
            let (left, right) = (rank(lhs), rank(rhs))
            if left != right { return left < right }
            let byHeader = lhs.header.localizedCaseInsensitiveCompare(rhs.header)
            return byHeader == .orderedSame ? lhs.id < rhs.id : byHeader == .orderedAscending
        }
    }

    /// `com.apple.voice.enhanced.en-US.Samantha` gives `Samantha`.
    static func nameFromIdentifier(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    private static func normalized(_ language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        return language.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageCode(_ normalized: String?) -> String? {
        normalized?.split(separator: "-").first.map(String.init)
    }

    private static func qualityRank(_ quality: String) -> Int {
        ["Premium", "Enhanced", "Default", "Unknown"].firstIndex(of: quality) ?? 4
    }

    private static func rowOrder(_ lhs: Voice, _ rhs: Voice) -> Bool {
        let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        let (left, right) = (qualityRank(lhs.quality), qualityRank(rhs.quality))
        return left == right ? lhs.id < rhs.id : left < right
    }
}
