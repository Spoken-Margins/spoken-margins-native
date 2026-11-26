import Foundation

/// What a paste into the app found (#3782): a friend's share link, or whatever `ClipboardIntakeClassifier` makes of it.
///
/// Every place a link can be pasted classifies with this and not with `ClipboardIntakeClassifier` alone (Paste & go,
/// the Library's copied-link card, the Link or Podcast form). A share link pasted into those used to go to the article
/// import and come back as a web page the app could not read. The share extension compiles the classifier by itself
/// and has no share-link rule, so this lives in SessionKit, where `ShareLinkURL` does.
public enum PasteIntake: Equatable, Sendable {
    /// A link to a friend's Margins, already on `https`, to open as a tapped link is opened (`openShareLink`).
    case shareLink(URL)
    case intake(ClipboardIntake)

    public static func classify(_ content: String?) -> PasteIntake {
        if let link = PastedShareLink.first(in: content) { return .shareLink(link) }
        return .intake(ClipboardIntakeClassifier.classify(content))
    }

    /// The one web link a paste is, with a short note around it or not, for a field that takes only a link (the Link form
    /// and the model's paste buttons, #4809): a friend's share link or an `http(s)` link, else nil.
    public static func webLink(in content: String?) -> URL? {
        switch classify(content) {
        case .shareLink(let url):
            return url
        case .intake(.link(let url)):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        case .intake:
            return nil
        }
    }
}

/// Finds a share link in pasted text: `https://<share host>/l/…`, whole or cut short.
///
/// It looks at every word of the text before the classifier's one-line and length limits, so the link is found inside
/// the whole message a friend sent, and takes the first one. A link that lost part of its id or its key is still
/// a share link here: opening it says it isn't a share link (``ShareLinkURL`` rejects it), which is better than importing it as
/// a web page. `http` on a share host and a missing scheme are read as `https`. Only the exact share hosts count
/// (`www.` does not, as for a tapped link), and only paths that start with `/l/`: the join page and the rest of the
/// site are ordinary links.
public enum PastedShareLink {
    public static func first(in content: String?) -> URL? {
        guard let content else { return nil }
        for word in content.split(whereSeparator: { $0.isWhitespace }) {
            if let link = shareLink(in: String(word)) { return link }
        }
        return nil
    }

    private static func shareLink(in word: String) -> URL? {
        // Most words of a pasted article are not links; skip them before any parsing.
        guard word.contains("/l/") else { return nil }
        let candidate = linkStart(in: ClipboardIntakeClassifier.stripWrapping(word))
        let lowered = candidate.lowercased()
        let secure: String
        if lowered.hasPrefix("https://") {
            secure = candidate
        } else if lowered.hasPrefix("http://") {
            secure = "https://" + candidate.dropFirst("http://".count)
        } else if candidate.contains("://") {
            return nil
        } else {
            secure = "https://" + candidate
        }
        guard let components = URLComponents(string: secure), let host = components.host, !host.isEmpty,
              components.percentEncodedPath.hasPrefix("/l/"), let url = components.url,
              ShareLinkURL.isOnShareHost(url) else { return nil }
        return url
    }

    /// A link with no space before it, as in Markdown `[Hear it](https://…)` or `feed:https://…`, starts at its
    /// `http(s)://`. Only when what comes before is a bracket, quote or scheme opener, never a query parameter
    /// like `other.com?u=https://…`.
    private static func linkStart(in word: String) -> String {
        guard !word.lowercased().hasPrefix("http"), let scheme = word.range(of: "http", options: .caseInsensitive),
              let marker = word.range(of: "://", range: scheme.lowerBound..<word.endIndex),
              word[scheme.upperBound..<marker.lowerBound].allSatisfy({ $0 == "s" || $0 == "S" }) else { return word }
        let prefix = word[..<scheme.lowerBound]
        guard let last = prefix.last, "(<[\"'“‘«:".contains(last),
              !prefix.contains(where: { "/?&=#".contains($0) }) else { return word }
        return ClipboardIntakeClassifier.stripWrapping(String(word[scheme.lowerBound...]))
    }
}
