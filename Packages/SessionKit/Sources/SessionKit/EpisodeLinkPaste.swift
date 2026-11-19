import Foundation

/// An assistant's pasted answer to the "find something for a friend" prompt (#4674), read one suggestion per
/// line, and a judgement of what the app's link resolver made of each link (#4673). Pure: the resolving is the
/// caller's job, so the same rules serve the app's paste-back check and the host trial command.
public enum EpisodeLinkPaste {
    /// What a link points at, read from the address alone.
    public enum LinkKind: String, Codable, Sendable, CaseIterable {
        case appleEpisode = "apple_episode"
        case appleShow = "apple_show"
        case spotify
        case youtube
        case substack
        case other
    }

    /// One suggestion line: the link and what the assistant said it is.
    public struct Entry: Codable, Equatable, Sendable {
        public var url: String
        public var kind: LinkKind
        public var claimedShow: String?
        public var claimedTitle: String?
        /// The assistant marked the line "(show link)": it could not confirm an episode link.
        public var markedShowLink: Bool
        public var line: String

        public init(url: String, kind: LinkKind, claimedShow: String?, claimedTitle: String?, markedShowLink: Bool, line: String) {
            self.url = url
            self.kind = kind
            self.claimedShow = claimedShow
            self.claimedTitle = claimedTitle
            self.markedShowLink = markedShowLink
            self.line = line
        }
    }

    public enum Verdict: String, Codable, Sendable {
        /// Plays, and the episode's title matches the one the assistant named.
        case rightEpisode = "right_episode"
        /// Plays, but it is a different episode from the one named.
        case wrongEpisode = "wrong_episode"
        /// Plays, but the line named no episode title to check against.
        case unchecked
        /// The resolver could not turn the link into a playable episode.
        case failed
    }

    // MARK: Parsing

    /// The suggestion lines in `text`, first link per line. When any linked line uses the requested
    /// "fields | link" form, only those lines count, so a "Sources" list the assistant adds after its picks
    /// is not read as more picks; otherwise every line holding an http(s) link counts.
    public static func entries(in text: String) -> [Entry] {
        let all = text.components(separatedBy: .newlines).compactMap(entry(fromLine:))
        let formed = all.filter { entry in
            guard let urlStart = entry.line.range(of: entry.url)?.lowerBound else { return false }
            return entry.line[..<urlStart].contains("|")
        }
        return formed.isEmpty ? all : formed
    }

    public static func entry(fromLine rawLine: String) -> Entry? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let match = line.range(of: #"https?://[^\s<>\"'`]+"#, options: .regularExpression) else { return nil }
        let url = cleanedURL(String(line[match]))
        guard URL(string: url)?.host != nil else { return nil }

        var before = String(line[..<match.lowerBound])
        let markedShowLink = before.range(of: "(show link)", options: .caseInsensitive) != nil
        before = before.replacingOccurrences(of: "(show link)", with: "", options: .caseInsensitive)
        // A markdown link "[label](url)" leaves "[label](" before the address.
        before = before.replacingOccurrences(of: #"\[([^\]]*)\]\($"#, with: "$1", options: .regularExpression)

        let fields = before.split(separator: "|", omittingEmptySubsequences: false)
            .map { cleanedField(String($0)) }
        let (show, title) = showAndTitle(fields.first ?? "")
        return Entry(url: url, kind: kind(of: url), claimedShow: show, claimedTitle: title,
                     markedShowLink: markedShowLink, line: line)
    }

    public static func kind(of urlString: String) -> LinkKind {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return .other }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("podcasts.apple.com") || on("itunes.apple.com") {
            let episodeId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "i" })?.value
            return (episodeId?.isEmpty == false) ? .appleEpisode : .appleShow
        }
        if on("spotify.com") || on("spotify.link") { return .spotify }
        if on("youtube.com") || on("youtu.be") { return .youtube }
        if on("substack.com") { return .substack }
        return .other
    }

    private static func cleanedURL(_ raw: String) -> String {
        var url = raw
        // Trailing markdown or sentence punctuation is never part of a podcast address.
        while let last = url.last, ")]}>.,;:!?*_".contains(last) {
            if last == ")", url.filter({ $0 == "(" }).count >= url.filter({ $0 == ")" }).count { break }
            url.removeLast()
        }
        return url
    }

    private static func cleanedField(_ raw: String) -> String {
        var field = raw
        field = field.replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        field = field.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        field = field.replacingOccurrences(of: #"[\[\]`]"#, with: "", options: .regularExpression)
        field = field.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”*_:")))
        return field
    }

    private static func showAndTitle(_ field: String) -> (String?, String?) {
        guard !field.isEmpty else { return (nil, nil) }
        for separator in [" — ", " – ", " - ", ": "] {
            if let range = field.range(of: separator) {
                let show = field[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = field[range.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”")))
                return (show.isEmpty ? nil : show, title.isEmpty ? nil : title)
            }
        }
        return (nil, field)
    }

    // MARK: Judging

    /// What the resolver's `result` means for `entry`.
    public static func verdict(for entry: Entry, result: LinkResolutionResult) -> Verdict {
        guard result.status == .playable, let candidate = result.selectedCandidate else { return .failed }
        guard let claimed = entry.claimedTitle, !normalizedTokens(claimed).isEmpty else { return .unchecked }
        return titlesMatch(claimed, candidate.title) ? .rightEpisode : .wrongEpisode
    }

    /// Whether two episode titles name the same episode: one contains the other, or most of the shorter
    /// title's words are in the longer one. Case, accents, curly quotes, "&" and punctuation don't count.
    public static func titlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedTokens(lhs), b = normalizedTokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let joinedA = a.joined(separator: " "), joinedB = b.joined(separator: " ")
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        if shorter.count >= 2 || shorter.first.map({ $0.count >= 6 }) == true {
            if joinedA == joinedB || joinedB.contains(joinedA) || joinedA.contains(joinedB) { return true }
        } else if joinedA == joinedB {
            return true
        }
        let shared = Set(shorter).intersection(Set(longer)).count
        return shorter.count >= 2 && Double(shared) / Double(shorter.count) >= 0.7
    }

    static let ignoredWords: Set<String> = ["the", "a", "an", "and", "of", "ep", "episode", "part", "pt"]

    static func normalizedTokens(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "[\u{2018}\u{2019}']", with: "", options: .regularExpression)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !ignoredWords.contains($0) }
    }
}
