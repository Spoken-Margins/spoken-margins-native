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
    /// OPML 2.0 `category` values (#4046): a comma-separated list of slash paths. The leading slash is dropped and a
    /// path stays one name, so `/Tech/AI` is the one name "Tech/AI". Blank and repeated names are dropped.
    public var categories: [String] = []
    /// The Podcasting 2.0 `podcast:guid` the row carries, trimmed; nil when absent or blank.
    public var podcastGUID: String?
    /// Our own namespaced attributes (`sm:skip`, `sm:more`, `sm:via`). Other apps ignore them.
    public var sm = OPMLSpokenMarginsAttributes()

    /// The lists this row belongs to: every folder it sat in, then its categories, each once.
    public var listNames: [String] { OPMLListNames.merged(folders, categories) }
}

/// The `https://spokenmargins.com/ns/lists/1` attributes on a feed row (#4046). Word lists are comma-separated.
public struct OPMLSpokenMarginsAttributes: Equatable, Sendable {
    public static let namespace = "https://spokenmargins.com/ns/lists/1"
    public var skip: [String] = []
    public var more: [String] = []
    /// The title of the included list this show came in through.
    public var via: String?
}

/// A row that points at another OPML file (`type="include"`, OPML 2.0). Reading it fetches nothing.
public struct OPMLInclude: Equatable, Sendable {
    public var url: String
    public var title: String
}

enum OPMLListNames {
    /// Trims, drops leading slashes and blanks, and keeps the first of names that are the same without case,
    /// diacritics or Unicode normalisation.
    static func clean(_ raw: [String]) -> [String] {
        var seen: [String] = []
        for entry in raw {
            var name = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            while name.hasPrefix("/") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(where: { FollowListName.sameName($0, name) }) else { continue }
            seen.append(name)
        }
        return seen
    }

    static func merged(_ folders: [String], _ categories: [String]) -> [String] {
        clean(folders + categories)
    }

    static func normalizedGUID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func words(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

public struct OPMLDocument: Equatable, Sendable {
    public var title: String?
    /// Feed outlines in file order, duplicates included. Episode outlines (Overcast's
    /// extended export) are not feeds and are skipped.
    public var feeds: [OPMLFeed]
    /// Outlines that looked like feeds but had no usable http(s) feed URL.
    public var unusableOutlineCount: Int
    /// `type="include"` rows in file order (#4046).
    public var includes: [OPMLInclude] = []
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
        let parser = makeXMLParser(data)
        parser.delegate = delegate
        let finished = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard finished else {
            throw OPMLError.malformed(parser.parserError.map { String(describing: $0) } ?? "unknown")
        }
        guard delegate.sawOPMLRoot else { throw OPMLError.notOPML }
        // Some XMLParser builds accept a truncated file; a cut-off export must not import half its feeds silently.
        guard delegate.sawOPMLEnd else { throw OPMLError.malformed("the file ends before </opml>") }
        return OPMLDocument(title: delegate.title, feeds: delegate.feeds, unusableOutlineCount: delegate.unusable, includes: delegate.includes)
    }

    /// The one place parse's XMLParser is configured: external entities are never resolved.
    /// Tests check these settings directly, because whether a resolving parser would actually
    /// substitute a SYSTEM entity differs by platform (Apple's XMLParser doesn't, in practice).
    static func makeXMLParser(_ data: Data) -> XMLParser {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        return parser
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    let limits: OPMLLimits
    var failure: OPMLError?
    var sawOPMLRoot = false
    var sawOPMLEnd = false
    var title: String?
    var feeds: [OPMLFeed] = []
    var includes: [OPMLInclude] = []
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
        if type == "include", attributes["xmlurl"] == nil {
            // OPML 2.0 include: a pointer to another file. Nothing is fetched here, and it has no children that matter.
            outlineStack.append((nil, false))
            guard let includeURL = attributes["url"].flatMap(OPMLParser.webURL) else { unusable += 1; return }
            includes.append(OPMLInclude(url: includeURL, title: label.flatMap { $0.isEmpty ? nil : $0 } ?? includeURL))
            return
        }
        if let rawURL = attributes["xmlurl"] ?? attributes["url"].flatMap({ type == "rss" ? $0 : nil }) {
            outlineStack.append((nil, true))
            guard let feedURL = OPMLParser.webURL(rawURL) else { unusable += 1; return }
            feeds.append(OPMLFeed(
                title: label.flatMap { $0.isEmpty ? nil : $0 } ?? feedURL,
                feedURL: feedURL,
                websiteURL: attributes["htmlurl"].flatMap(OPMLParser.webURL),
                folders: outlineStack.compactMap(\.folder),
                categories: OPMLListNames.clean(OPMLListNames.words(attributes["category"])),
                podcastGUID: attributes["podcast:guid"].flatMap { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                },
                sm: OPMLSpokenMarginsAttributes(
                    skip: OPMLListNames.words(attributes["sm:skip"]),
                    more: OPMLListNames.words(attributes["sm:more"]),
                    via: attributes["sm:via"].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
                )
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
}

extension OPMLParser {
    /// An http(s) link with a host, trimmed; nil for anything else (feed:, itpc:, a bare word).
    static func webURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              !(components.host ?? "").isEmpty else { return nil }
        return trimmed
    }
}

/// #4284: the feed links a Shortcut hands over, read into the same document an OPML file gives, so the
/// import preview and follow path are OPML's. Apple Podcasts on iPhone has no OPML export, but Shortcuts'
/// "Get Podcasts from Library" gives each show's Feed URL. Each entry may hold several lines; each line is
/// one show: a feed link, optionally with the show's name around it ("Name https://…" or "Name: https://…").
/// A line with no usable feed link (a junk line, an Apple Podcasts store page, a feed: or itpc: link)
/// counts as unusable; blank lines are skipped.
public enum FeedLinkListParser {
    public static func parse(_ entries: [String], limits: OPMLLimits = OPMLLimits()) throws -> OPMLDocument {
        guard entries.reduce(0, { $0 + $1.utf8.count }) <= limits.maximumBytes else { throw OPMLError.tooLarge }
        var feeds: [OPMLFeed] = []
        var unusable = 0
        for line in entries.flatMap({ $0.components(separatedBy: .newlines) }) {
            let words = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            guard feeds.count + unusable < limits.maximumOutlines else { throw OPMLError.tooManyOutlines }
            guard let index = words.firstIndex(where: { feedLink(in: $0) != nil }), let link = feedLink(in: words[index]) else {
                unusable += 1
                continue
            }
            let url = link.url
            var rest = words
            rest.remove(at: index)
            if !link.leading.isEmpty { rest.insert(link.leading, at: index) }
            let title = rest.filter { OPMLParser.webURL(trimmingWrappers($0)) == nil }
                .joined(separator: " ")
                .trimmingCharacters(in: separators)
            feeds.append(OPMLFeed(title: title.isEmpty ? url : title, feedURL: url, websiteURL: nil, folders: []))
        }
        return OPMLDocument(title: nil, feeds: feeds, unusableOutlineCount: unusable)
    }

    /// The feed link in a word, and any name stuck to its front. A Shortcut that puts the show's name and its
    /// link side by side in one Text with no space between ("Hard Forkhttps://…", "Hard Fork:https://…") gives a
    /// word that is not a link by itself; reading from its first "http(s)://" keeps the line usable. Text that
    /// holds a path before the scheme ("example.com/go?to=https://…") stays unusable.
    static func feedLink(in word: String) -> (url: String, leading: String)? {
        if let url = feedURL(in: word) { return (url, "") }
        let schemes = [word.range(of: "http://", options: .caseInsensitive), word.range(of: "https://", options: .caseInsensitive)]
        guard let earliest = schemes.compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let leading = String(word[..<earliest.lowerBound])
        guard !leading.isEmpty, !leading.contains("/"), let url = feedURL(in: String(word[earliest.lowerBound...])) else { return nil }
        return (url, leading)
    }

    /// A word that is a feed link once the brackets, quotes and punctuation around it are dropped. An Apple
    /// Podcasts store page is a web link but not a feed, so following it would only fail later.
    static func feedURL(in word: String) -> String? {
        guard let url = OPMLParser.webURL(trimmingWrappers(word)),
              let host = URLComponents(string: url)?.host?.lowercased(),
              host != "podcasts.apple.com", host != "itunes.apple.com", !host.hasSuffix(".itunes.apple.com") else { return nil }
        return url
    }

    private static func trimmingWrappers(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'“”‘’,;"))
    }

    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–—|•,;\"“”"))
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
    /// Known gap: a follow stores the feed's own self link, which can differ from the URL it was
    /// followed from (a moved host, an old redirect). Such a feed shows as new here; following it
    /// again updates the same subscription rather than adding one. Matching both needs the
    /// followed-from URL stored with the follow (a storage change, raised on #187).
    public var alreadyFollowed: [OPMLFeed]
    /// Repeats of a feed earlier in the same file.
    public var duplicatesInFile: [OPMLFeed]
    public var unusableOutlineCount: Int
    /// The lists the file holds, for the import screen's "Lists in this file" (#4046).
    public var lists: [OPMLPlannedList] = []
}

public enum OPMLImportPlanner {
    /// - Parameter existingLists: the listener's lists, so a list in the file with the same name shows that it adds to it.
    public static func preview(
        _ document: OPMLDocument, existing subscriptions: [FeedSubscription], existingLists: [FollowList] = []
    ) -> OPMLImportPreview {
        var followedKeys = Set(subscriptions.compactMap { FeedURLKey.make($0.source.canonicalURL) })
        var toFollow: [SourceCandidate] = []
        var already: [OPMLFeed] = []
        var duplicates: [OPMLFeed] = []
        var seenInFile = Set<String>()
        for feed in document.feeds {
            guard let key = FeedURLKey.make(feed.feedURL) else { continue }
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
                // The file names the feed itself, so it is exact, unless we rewrote http to
                // https: that guesses the host serves the same feed over https.
                confidence: httpsURL == feed.feedURL ? .exact : .likely,
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
            unusableOutlineCount: document.unusableOutlineCount,
            lists: OPMLListPlanner.plan(document, existingLists: existingLists)
        )
    }

    /// The follow path requires https (ATS). An http feed is offered as https; if the host
    /// has no https, following fails visibly instead of silently downgrading.
    static func httpsFeedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.scheme?.lowercased() == "http" else { return raw }
        components.scheme = "https"
        return components.string ?? raw
    }
}

/// What following the ticked feeds from an import did.
public struct OPMLImportResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var candidate: SourceCandidate
        /// Shown on the feed's row, for example "The source did not return a supported feed."
        public var reason: String
    }

    public var followed: [SourceCandidate] = []
    public var failed: [Failure] = []
    /// Ticked feeds not tried because the import was cancelled part way.
    public var notTried: [SourceCandidate] = []
}

public enum OPMLImportRunner {
    /// Follows the ticked feeds of `preview`, one at a time in file order, through `follow`
    /// (the app's normal follow path). A feed that fails is recorded with its reason and the
    /// rest still follow. Nothing else is touched: no Library item, download or preparation.
    public static func follow(
        _ preview: OPMLImportPreview,
        selected: Set<String>,
        isolation: isolated (any Actor)? = #isolation,
        // Optional rather than defaulted closures: a closure default next to an isolated
        // parameter crashes Swift 6.2's region checker in @MainActor callers.
        describe: ((Error) -> String)? = nil,
        progress: ((Int, Int) -> Void)? = nil,
        using follow: (SourceCandidate) async throws -> Void
    ) async -> OPMLImportResult {
        let ticked = preview.toFollow.filter { selected.contains($0.id) }
        var result = OPMLImportResult()
        for (index, candidate) in ticked.enumerated() {
            if Task.isCancelled {
                result.notTried = Array(ticked[index...])
                break
            }
            progress?(index, ticked.count)
            do {
                try await follow(candidate)
                result.followed.append(candidate)
            } catch where Task.isCancelled {
                // Stopping cancels the feed in flight too; it wasn't followed, and it didn't fail.
                result.notTried = Array(ticked[index...])
                break
            } catch {
                result.failed.append(.init(candidate: candidate, reason: describe?(error) ?? error.localizedDescription))
            }
        }
        progress?(ticked.count - result.notTried.count, ticked.count)
        return result
    }
}

public struct OPMLExport: Equatable, Sendable {
    public var data: Data
    public var exportedCount: Int
    /// Private feeds (a per-subscriber secret in the link) are left out so they can't
    /// leave the device in a shared file (#168). The UI should say how many.
    public var withheldPrivateCount: Int
}

/// An include row for an export (#4046): another list this one picks up by its web address.
public struct OPMLExportInclude: Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public enum OPMLExporter {
    /// - Parameters:
    ///   - lists: the follow lists. A show is written with a `category` for each list it is in (`/<name>`, comma-separated),
    ///     so any reader that knows `category` keeps the grouping and any that doesn't still imports every feed.
    ///   - podcastGUIDs: a subscription's Podcasting 2.0 GUID by subscription id, written as `podcast:guid` where known.
    ///   - includes: other lists this one includes, written as `type="include"` rows before the shows.
    ///   - includedVia: by subscription id, the title of the included list a show came in through, written as `sm:via`.
    ///     The show is also written as a plain row, so a reader that ignores `include` still gets it.
    ///
    /// With none of those the output is what it was before lists: plain rows, no namespaces. Private feeds are left out,
    /// and so is everything attached to them.
    public static func export(
        _ subscriptions: [FeedSubscription],
        title: String = "Spoken Margins follows",
        createdAt: Date = Date(),
        lists: [FollowList] = [],
        podcastGUIDs: [String: String] = [:],
        includes: [OPMLExportInclude] = [],
        includedVia: [String: String] = [:]
    ) -> OPMLExport {
        var rows: [String] = []
        for include in includes {
            guard let url = OPMLParser.webURL(include.url), ShareableLinkPolicy.shareableLink(url) != nil else { continue }
            let name = escape(include.title)
            rows.append(#"    <outline type="include" text="\#(name)" title="\#(name)" url="\#(escape(url))"/>"#)
        }
        var exported = 0
        var withheld = 0
        var usesGUID = false
        var usesVia = false
        let chipOrdered = FollowListName.chipOrder(lists)
        for subscription in subscriptions.sorted(by: { ($0.source.title ?? "").localizedCaseInsensitiveCompare($1.source.title ?? "") == .orderedAscending }) {
            let url = subscription.source.canonicalURL
            guard ShareableLinkPolicy.shareableLink(url) != nil else { withheld += 1; continue }
            let name = escape(subscription.source.title ?? subscription.source.host)
            var attributes = #"type="rss" text="\#(name)" title="\#(name)" xmlUrl="\#(escape(url))""#
            let key = FeedURLKey.make(url)
            let guid = OPMLListNames.normalizedGUID(ShareableLinkPolicy.shareableEpisodeGUID(OPMLListNames.normalizedGUID(podcastGUIDs[subscription.id])))
            let categories = chipOrdered.filter { $0.contains(feedKey: key, podcastGUID: guid) }
                .map { "/" + FollowListName.cleaned($0.name.replacingOccurrences(of: ",", with: " ")) }
            if !categories.isEmpty { attributes += #" category="\#(escape(categories.joined(separator: ",")))""# }
            if let guid { attributes += #" podcast:guid="\#(escape(guid))""#; usesGUID = true }
            if let via = includedVia[subscription.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !via.isEmpty {
                attributes += #" sm:via="\#(escape(via))""#
                usesVia = true
            }
            rows.append("    <outline \(attributes)/>")
            exported += 1
        }
        var root = #"<opml version="2.0""#
        if usesGUID { root += #" xmlns:podcast="https://podcastindex.org/namespace/1.0""# }
        if usesVia { root += " xmlns:sm=\"\(OPMLSpokenMarginsAttributes.namespace)\"" }
        root += ">"
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            root,
            "  <head>",
            "    <title>\(escape(title))</title>",
            "    <dateCreated>\(rfc822(createdAt))</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        lines += rows
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
