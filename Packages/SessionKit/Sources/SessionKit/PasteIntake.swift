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
}

/// Finds a share link in pasted text: `https://<share host>/l/…`, whole or cut short.
///
/// It looks at every word of the text before the classifier's one-line and length limits, so the link is found inside
/// the whole message a friend sent, and takes the first one. A link that lost part of its id or its key is still
/// a share link here: opening it says it is cut off (``ShareLinkURL`` rejects it), which is better than importing it as
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
        let candidate = ClipboardIntakeClassifier.stripWrapping(word)
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
}
