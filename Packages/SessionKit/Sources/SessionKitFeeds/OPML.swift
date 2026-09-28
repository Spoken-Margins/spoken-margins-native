import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SessionKit

// OPML import and export (B1 M2). Import turns another app's subscription export into
// seam I1 candidates plus a preview of what will be followed; export writes the app's
// own follows. Neither fetches a feed or downloads an episode.

public struct OPMLLimits: Equatable, Sendable {
    public var maximumBytes: Int
    public var maximumOutlines: Int
    public var maximumDepth: Int

    public init(maximumBytes: Int = 4 * 1_024 * 1_024, maximumOutlines: Int = 5_000, maximumDepth: Int = 32) {
        self.maximumBytes = maximumBytes
        self.maximumOutlines = maximumOutlines
        self.maximumDepth = maximumDepth
    }
}

public struct OPMLFeed: Equatable, Sendable {
    public var title: String
    public var feedURL: String
    public var websiteURL: String?
    /// Titles of the folders the outline sat in, outermost first (for example ["Tech"]).
    public var folders: [String]
}

public struct OPMLDocument: Equatable, Sendable {
    public var title: String?
    /// Feed outlines in file order, duplicates included. Episode outlines (Overcast's
    /// extended export) are not feeds and are skipped.
    public var feeds: [OPMLFeed]
    /// Outlines that looked like feeds but had no usable http(s) feed URL.
    public var unusableOutlineCount: Int
}

public enum OPMLError: Error, Equatable, Sendable {
    case tooLarge
    case tooManyOutlines
    case tooDeep
    case notOPML
    case malformed(String)
}

public enum OPMLParser {
    public static func parse(_ data: Data, limits: OPMLLimits = OPMLLimits()) throws -> OPMLDocument {
        guard data.count <= limits.maximumBytes else { throw OPMLError.tooLarge }
        let delegate = OPMLDelegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let finished = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard finished else {
            throw OPMLError.malformed(parser.parserError.map { String(describing: $0) } ?? "unknown")
        }
        guard delegate.sawOPMLRoot else { throw OPMLError.notOPML }
        // Some XMLParser builds accept a truncated file; a cut-off export must not import half its feeds silently.
        guard delegate.sawOPMLEnd else { throw OPMLError.malformed("the file ends before </opml>") }
        return OPMLDocument(title: delegate.title, feeds: delegate.feeds, unusableOutlineCount: delegate.unusable)
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    let limits: OPMLLimits
    var failure: OPMLError?
    var sawOPMLRoot = false
    var sawOPMLEnd = false
    var title: String?
    var feeds: [OPMLFeed] = []
    var unusable = 0

    private var depth = 0
    private var outlineCount = 0
    private var inHeadTitle = false
    private var titleText = ""
    /// One frame per open <outline>: its folder title, or nil when it is a feed (children of a feed are episodes).
    private var outlineStack: [(folder: String?, isFeed: Bool)] = []

    init(limits: OPMLLimits) { self.limits = limits }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth > limits.maximumDepth { fail(.tooDeep, parser); return }
        let name = elementName.lowercased()
        if depth == 1 {
            guard name == "opml" else { fail(.notOPML, parser); return }
            sawOPMLRoot = true
        }
        if name == "title", depth == 3 { inHeadTitle = true; titleText = "" }
        guard name == "outline" else { return }
        outlineCount += 1
        if outlineCount > limits.maximumOutlines { fail(.tooManyOutlines, parser); return }

        // Attribute names vary in case between apps (xmlUrl, xmlurl, XMLURL).
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict { attributes[key.lowercased()] = value }
        let type = attributes["type"]?.lowercased()
        let insideFeed = outlineStack.contains { $0.isFeed }
        let label = (attributes["title"] ?? attributes["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideFeed {
            // Overcast nests episodes (type="podcast-episode") inside each feed.
            outlineStack.append((nil, false))
            return
        }
        if let rawURL = attributes["xmlurl"] ?? attributes["url"].flatMap({ type == "rss" ? $0 : nil }) {
            outlineStack.append((nil, true))
            guard let feedURL = Self.webURL(rawURL) else { unusable += 1; return }
            feeds.append(OPMLFeed(
                title: label.flatMap { $0.isEmpty ? nil : $0 } ?? feedURL,
                feedURL: feedURL,
                websiteURL: attributes["htmlurl"].flatMap(Self.webURL),
                folders: outlineStack.compactMap(\.folder)
            ))
            return
        }
        if type == "rss" { unusable += 1 }
        outlineStack.append((label, false))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inHeadTitle { titleText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "title", inHeadTitle {
            inHeadTitle = false
            let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { title = trimmed }
        }
        if name == "outline", !outlineStack.isEmpty { outlineStack.removeLast() }
        if name == "opml", depth == 1 { sawOPMLEnd = true }
        depth = max(0, depth - 1)
    }

    private func fail(_ error: OPMLError, _ parser: XMLParser) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    static func webURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !(components.host ?? "").isEmpty else { return nil }
        return trimmed
    }
}

/// What importing a file would do, for the preview screen. Nothing is followed until
/// the listener confirms `toFollow` (all, or a subset).
public struct OPMLImportPreview: Equatable, Sendable {
    public var documentTitle: String?
    /// New feeds, as I1 candidates (resolverId "opml", confidence exact: the file names the feed).
    /// Their kind is provisional: OPML doesn't say podcast or blog, and the follow path
    /// decides from the feed's items, as it does for any link.
    public var toFollow: [SourceCandidate]
    /// Feeds already followed, matched by feed URL (scheme and host case, http/https and a trailing slash ignored).
    public var alreadyFollowed: [OPMLFeed]
    /// Repeats of a feed earlier in the same file.
    public var duplicatesInFile: [OPMLFeed]
    public var unusableOutlineCount: Int
}

public enum OPMLImportPlanner {
    public static func preview(_ document: OPMLDocument, existing subscriptions: [FeedSubscription]) -> OPMLImportPreview {
        var followedKeys = Set(subscriptions.compactMap { feedKey($0.source.canonicalURL) })
        var toFollow: [SourceCandidate] = []
        var already: [OPMLFeed] = []
        var duplicates: [OPMLFeed] = []
        var seenInFile = Set<String>()
        for feed in document.feeds {
            guard let key = feedKey(feed.feedURL) else { continue }
            if followedKeys.contains(key) {
                if seenInFile.insert(key).inserted { already.append(feed) } else { duplicates.append(feed) }
                continue
            }
            guard seenInFile.insert(key).inserted else { duplicates.append(feed); continue }
            let httpsURL = httpsFeedURL(feed.feedURL)
            toFollow.append(SourceCandidate(
                id: "opml:\(toFollow.count):\(key)",
                kind: .podcastFeed,
                contentKind: .podcast,
                title: feed.title,
                websiteURL: feed.websiteURL.flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil },
                feed: SourceCandidateFeed(url: httpsURL),
                confidence: .exact,
                reason: httpsURL == feed.feedURL
                    ? "Listed in the imported file"
                    : "Listed in the imported file (http link, will be tried over https)",
                resolverId: "opml"
            ))
            followedKeys.insert(key)
        }
        return OPMLImportPreview(
            documentTitle: document.title,
            toFollow: toFollow,
            alreadyFollowed: already,
            duplicatesInFile: duplicates,
            unusableOutlineCount: document.unusableOutlineCount
        )
    }

    /// Scheme-free key: an http feed in the file and its https subscription are the same feed.
    static func feedKey(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        return components.string
    }

    /// The follow path requires https (ATS). An http feed is offered as https; if the host
    /// has no https, following fails visibly instead of silently downgrading.
    static func httpsFeedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.scheme?.lowercased() == "http" else { return raw }
        components.scheme = "https"
        return components.string ?? raw
    }
}

public struct OPMLExport: Equatable, Sendable {
    public var data: Data
    public var exportedCount: Int
    /// Private feeds (a per-subscriber secret in the link) are left out so they can't
    /// leave the device in a shared file (#168). The UI should say how many.
    public var withheldPrivateCount: Int
}

public enum OPMLExporter {
    public static func export(_ subscriptions: [FeedSubscription], title: String = "Spoken Margins follows", createdAt: Date = Date()) -> OPMLExport {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(title))</title>",
            "    <dateCreated>\(rfc822(createdAt))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        var exported = 0
        var withheld = 0
        for subscription in subscriptions.sorted(by: { ($0.source.title ?? "").localizedCaseInsensitiveCompare($1.source.title ?? "") == .orderedAscending }) {
            let url = subscription.source.canonicalURL
            guard ShareableLinkPolicy.shareableLink(url) != nil else { withheld += 1; continue }
            let name = escape(subscription.source.title ?? subscription.source.host)
            lines.append(#"    <outline type="rss" text="\#(name)" title="\#(name)" xmlUrl="\#(escape(url))"/>"#)
            exported += 1
        }
        lines += ["  </body>", "</opml>", ""]
        return OPMLExport(data: Data(lines.joined(separator: "\n").utf8), exportedCount: exported, withheldPrivateCount: withheld)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n", "\r", "\t": result += " "
            default:
                // XML 1.0 forbids other control characters.
                if scalar.value < 0x20 { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
