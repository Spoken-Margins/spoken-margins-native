import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SessionKit

public struct FeedParserLimits: Equatable, Sendable {
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024

    public var maximumBytes: Int
    public var maximumEntries: Int
    public var maximumXMLDepth: Int

    public init(maximumBytes: Int = FeedParserLimits.defaultMaximumBytes, maximumEntries: Int = 200, maximumXMLDepth: Int = 64) {
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
        self.maximumXMLDepth = maximumXMLDepth
    }
}

public enum ParsedFeedFormat: String, Equatable, Sendable { case rss, atom, json }

public struct ParsedFeedItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var author: String?
    public var summary: String?
    public var publishedAt: Date?
    public var audioURL: String?
    /// Episode length from `itunes:duration`, when the feed gives one.
    public var durationMs: Int? = nil
    /// The item's full body, tags stripped, from RSS `content:encoded`, Atom `content` or JSON Feed
    /// `content_html`/`content_text`, kept apart from the short description so a full post can be
    /// told from show notes (#545). `summary` is unchanged: it still takes the last of these.
    public var content: String? = nil
    public var publisherPlatform: String? = nil
    /// The item's `<guid>`, Atom `id` or JSON Feed `id` as written, without the display cleanup
    /// `id` gets; nil when the feed gives none (`id` then falls back to the link).
    public var guid: String? = nil
    /// The item's own picture (#3864). Order: `itunes:image`, `media:thumbnail`,
    /// `media:content` of medium `image`, an `image/*` enclosure; JSON Feed `image`, then
    /// `banner_image`. Https only; nil when the entry names none. It is never the show's image,
    /// which stays on `ParsedFeed.imageURL`.
    public var imageURL: String? = nil
    /// The item's first enclosure that isn't a picture, as written, whatever its type (#4640): RSS `<enclosure>`, Atom
    /// `link rel="enclosure"`, JSON Feed `attachments`. `audioURL` keeps its own rules; the article feed route reads
    /// these to decide for itself.
    public var enclosureURL: String? = nil
    public var enclosureType: String? = nil
    /// The enclosure's `length` (or JSON Feed `size_in_bytes`), when the feed gives a positive one.
    public var enclosureLengthBytes: Int? = nil
    /// The publisher asked directories not to list this episode: `<itunes:block>Yes</itunes:block>` on the episode or
    /// on the whole show (#5340; Apple's convention, https://podcasters.apple.com/support/823-podcast-requirements).
    /// Any other value, or no tag, is false. It restricts what leaves the device on its own
    /// (`AutomaticSourceAccess`); it is not proof that the feed is private.
    public var publisherBlocked: Bool = false
}

public struct ParsedFeed: Equatable, Sendable {
    public var format: ParsedFeedFormat
    public var title: String
    public var homePageURL: String?
    public var feedURL: String?
    public var items: [ParsedFeedItem]
    /// The show's own artwork: RSS `<itunes:image href>` or `<image><url>`, Atom `<logo>` or
    /// `<icon>`, JSON Feed `icon`. Https only; nil when the feed names none (#773).
    public var imageURL: String? = nil
    /// The show's own `<itunes:block>Yes</itunes:block>` (#5340). Every item of a blocked show is blocked too.
    public var publisherBlocked: Bool = false
}

public enum FeedParserError: Error, LocalizedError, Equatable {
    case responseTooLarge
    case malformed
    case tooDeep
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "The feed exceeds the 16 MB safety limit."
        case .malformed: return "That link isn't a podcast or news feed. Check the address."
        case .tooDeep: return "That link isn't a podcast or news feed. Check the address."
        case .unsupported: return "That link isn't a podcast or news feed. Check the address."
        }
    }
}

public final class FeedParser: @unchecked Sendable {
    private let limits: FeedParserLimits
    public init(limits: FeedParserLimits = FeedParserLimits()) { self.limits = limits }

    public func parse(data: Data, contentType: String? = nil) throws -> ParsedFeed {
        guard data.count <= limits.maximumBytes else { throw FeedParserError.responseTooLarge }
        let trimmed = data.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        if trimmed.first == 0x7B {
            return try parseJSON(data)
        }
        let delegate = XMLFeedDelegate(limits: limits)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse() else {
            if delegate.tooDeep { throw FeedParserError.tooDeep }
            throw FeedParserError.malformed
        }
        guard let format = delegate.format else { throw FeedParserError.unsupported }
        return ParsedFeed(
            format: format,
            title: delegate.feedTitle.nilIfEmpty ?? "Untitled Source",
            homePageURL: delegate.homePageURL.nilIfEmpty,
            feedURL: delegate.feedURL.nilIfEmpty,
            items: Array(delegate.items.prefix(limits.maximumEntries)).map { item in
                var item = item
                item.publisherPlatform = delegate.feedGenerator.nilIfEmpty?.lowercased()
                // The show's block may come after its items in the file, so it is applied once the whole feed is read.
                if delegate.channelBlocked { item.publisherBlocked = true }
                return item
            },
            imageURL: [delegate.itunesImage, delegate.channelImage, delegate.atomLogo, delegate.atomIcon]
                .lazy.compactMap(httpsLink).first,
            publisherBlocked: delegate.channelBlocked
        )
    }

    private func parseJSON(_ data: Data) throws -> ParsedFeed {
        struct JSONFeed: Decodable {
            struct Item: Decodable {
                struct Attachment: Decodable {
                    var url: String; var mime_type: String?; var size_in_bytes: Int?
                    enum CodingKeys: String, CodingKey { case url, mime_type, size_in_bytes }
                    // The size is only a hint for the article feed route (#4640): a string or out-of-range value is
                    // dropped, never a reason to reject the whole feed.
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        url = try c.decode(String.self, forKey: .url)
                        mime_type = try c.decodeIfPresent(String.self, forKey: .mime_type)
                        size_in_bytes = try? c.decodeIfPresent(Int.self, forKey: .size_in_bytes)
                    }
                }
                var id: String?
                var url: String?
                var external_url: String?
                var title: String?
                var content_text: String?
                var content_html: String?
                var summary: String?
                var date_published: String?
                var authors: [Author]?
                var author: Author?
                var attachments: [Attachment]?
                var image: String?
                var banner_image: String?
            }
            struct Author: Decodable { var name: String? }
            var version: String
            var title: String
            var home_page_url: String?
            var feed_url: String?
            var icon: String?
            var items: [Item]
        }
        let decoded: JSONFeed
        do { decoded = try JSONDecoder().decode(JSONFeed.self, from: data) }
        catch { throw FeedParserError.malformed }
        guard decoded.version.contains("jsonfeed.org/version") else { throw FeedParserError.unsupported }
        let formatter = ISO8601DateFormatter()
        let items = decoded.items.prefix(limits.maximumEntries).compactMap { item -> ParsedFeedItem? in
            let audio = item.attachments?.first { ($0.mime_type ?? "").lowercased().hasPrefix("audio/") }?.url.nilIfEmpty
            // An episode with audio but no link is still an episode (#179); its audio stands in for the link.
            guard let url = item.url?.nilIfEmpty ?? item.external_url?.nilIfEmpty ?? audio else { return nil }
            let rawSummary = item.summary ?? item.content_text ?? item.content_html
            let content = item.content_html.map(FeedArticleBodyText.html) ?? item.content_text.map(sanitize)
            let author = item.authors?.compactMap(\.name).joined(separator: ", ").nilIfEmpty ?? item.author?.name
            let enclosure = item.attachments?.first { !$0.url.isEmpty && !($0.mime_type ?? "").lowercased().hasPrefix("image/") }
            return ParsedFeedItem(
                id: item.id ?? url,
                title: sanitize(item.title ?? "Untitled"),
                url: url,
                author: author.map(sanitize),
                summary: rawSummary.map(sanitize),
                publishedAt: item.date_published.flatMap(formatter.date(from:)),
                audioURL: audio,
                content: content?.nilIfEmpty,
                guid: item.id?.nilIfEmpty,
                imageURL: [item.image, item.banner_image].lazy.compactMap { $0.flatMap(httpsLink) }.first
                    ?? item.attachments?.lazy.filter { ($0.mime_type ?? "").lowercased().hasPrefix("image/") }
                        .compactMap { httpsLink($0.url) }.first,
                enclosureURL: enclosure?.url,
                enclosureType: enclosure?.mime_type?.nilIfEmpty,
                enclosureLengthBytes: enclosure?.size_in_bytes.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return ParsedFeed(format: .json, title: sanitize(decoded.title), homePageURL: decoded.home_page_url, feedURL: decoded.feed_url, items: items, imageURL: decoded.icon.flatMap(httpsLink))
    }
}

private final class XMLFeedDelegate: NSObject, XMLParserDelegate {
    let limits: FeedParserLimits
    var format: ParsedFeedFormat?
    var feedTitle = ""
    var feedGenerator = ""
    var homePageURL = ""
    var feedURL = ""
    var itunesImage = ""
    var channelImage = ""
    var atomLogo = ""
    var atomIcon = ""
    var channelBlocked = false
    var items: [ParsedFeedItem] = []
    var tooDeep = false
    private var inChannelImage = false
    private var depth = 0
    private var currentElement = ""
    private var text = ""
    private var inEntry = false
    private var item: ItemBuilder?

    init(limits: FeedParserLimits) { self.limits = limits }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth > limits.maximumXMLDepth { tooDeep = true; parser.abortParsing(); return }
        let name = normalized(qName ?? elementName)
        currentElement = name
        text = ""
        if name == "rss" { format = .rss }
        if name == "feed" && format == nil { format = .atom }
        if name == "item" || name == "entry" {
            inEntry = true
            item = ItemBuilder()
        }
        if inEntry { collectItemImage(name: name, attributes: attributeDict) }
        if !inEntry, name == "image" {
            // `<itunes:image href>` carries the link itself; RSS `<image>` holds a `<url>` child.
            if let href = attributeDict["href"] {
                if itunesImage.isEmpty { itunesImage = href }
            } else {
                inChannelImage = true
            }
        }
        if format == .atom, name == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if inEntry {
                if rel == "alternate" { item?.url = href }
                if rel == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("audio/") { item?.audioURL = href }
                if rel == "enclosure" { item?.noteEnclosure(url: href, type: attributeDict["type"], length: attributeDict["length"]) }
                if rel == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("image/"), item?.enclosureImage == nil { item?.enclosureImage = href }
            } else if rel == "self" { feedURL = href } else if rel == "alternate" { homePageURL = href }
        }
        if format == .rss, name == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("audio/") {
            item?.audioURL = attributeDict["url"]
        }
        if format == .rss, name == "enclosure", let url = attributeDict["url"] {
            item?.noteEnclosure(url: url, type: attributeDict["type"], length: attributeDict["length"])
        }
        if format == .rss, name == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("image/"),
           item?.enclosureImage == nil {
            item?.enclosureImage = attributeDict["url"]
        }
    }

    /// An entry's own picture candidates, kept apart so `ItemBuilder` can apply the precedence.
    /// `normalized` drops the namespace prefix, so `media:content` arrives as "content": it counts
    /// only with a `url` and a medium or type of image (an Atom `<content type="html">` has neither).
    private func collectItemImage(name: String, attributes: [String: String]) {
        switch name {
        case "image":
            if let href = attributes["href"], item?.itunesImage == nil { item?.itunesImage = href }
        case "thumbnail":
            if let url = attributes["url"], item?.mediaThumbnail == nil { item?.mediaThumbnail = url }
        case "content":
            guard let url = attributes["url"], item?.mediaContentImage == nil else { return }
            let medium = (attributes["medium"] ?? "").lowercased()
            let type = (attributes["type"] ?? "").lowercased()
            if medium == "image" || (medium.isEmpty && type.hasPrefix("image/")) { item?.mediaContentImage = url }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = normalized(qName ?? elementName)
        let value = sanitize(text)
        if PublisherBlockSignal.isBlock(qName ?? elementName, namespaceURI: namespaceURI, value: text) {
            if inEntry { item?.blocked = true } else { channelBlocked = true }
        }
        if inEntry {
            switch name {
            case "title": item?.title = value
            case "link": if format == .rss && item?.url == nil { item?.url = value }
            case "guid", "id":
                item?.id = value
                // Kept as written: display cleanup would turn `episode&lt;42&gt;` into `episode`,
                // while the direct RSS import keeps `episode<42>`, and the GUIDs must match.
                item?.guid = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "description", "summary": item?.summary = value
            case "content", "encoded":
                item?.summary = value
                // An empty `media:content` also ends as "content"; it mustn't wipe a body.
                let content = FeedArticleBodyText.html(text)
                if !content.isEmpty { item?.content = content }
            case "author", "creator", "name": if item?.author == nil { item?.author = value }
            case "pubdate", "published", "updated": item?.published = value
            case "duration": item?.duration = value
            default: break
            }
        } else if inChannelImage {
            if name == "url", channelImage.isEmpty { channelImage = value }
            if name == "image" { inChannelImage = false }
        } else {
            if name == "generator", feedGenerator.isEmpty { feedGenerator = value }
            if name == "title", feedTitle.isEmpty { feedTitle = value }
            if name == "link", format == .rss, homePageURL.isEmpty { homePageURL = value }
            if name == "logo", format == .atom, atomLogo.isEmpty { atomLogo = value }
            if name == "icon", format == .atom, atomIcon.isEmpty { atomIcon = value }
        }
        if name == "item" || name == "entry" {
            if let built = item?.build(), items.count < limits.maximumEntries { items.append(built) }
            item = nil
            inEntry = false
        }
        text = ""
        depth = max(0, depth - 1)
    }

    private func normalized(_ name: String) -> String { name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased() }
}

private struct ItemBuilder {
    var id: String?
    var guid: String?
    var title: String?
    var url: String?
    var author: String?
    var summary: String?
    var published: String?
    var audioURL: String?
    var duration: String?
    var content: String?
    var itunesImage: String?
    var mediaThumbnail: String?
    var mediaContentImage: String?
    var enclosureImage: String?
    var enclosure: (url: String, type: String?, length: Int?)?
    var blocked = false
    /// Keeps the first enclosure that isn't a picture (#4640).
    mutating func noteEnclosure(url: String, type: String?, length: String?) {
        guard enclosure == nil, !url.isEmpty, !(type ?? "").lowercased().hasPrefix("image/") else { return }
        let bytes = length.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
        enclosure = (url, type?.nilIfEmpty, bytes)
    }
    func build() -> ParsedFeedItem? {
        // Podcast feeds, paid ones especially, often give episodes audio and a GUID but no
        // <link> (#179). The enclosure then stands in for the link, so identity falls back to
        // the GUID, then the enclosure URL. Items with neither a link nor audio are skipped.
        // Linked items are unchanged, so entries of feeds already followed keep their IDs.
        guard let url = url?.nilIfEmpty ?? audioURL?.nilIfEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        let rssFormatter = DateFormatter()
        rssFormatter.locale = Locale(identifier: "en_US_POSIX")
        rssFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return ParsedFeedItem(
            id: id?.nilIfEmpty ?? url,
            title: title?.nilIfEmpty ?? "Untitled",
            url: url,
            author: author?.nilIfEmpty,
            summary: summary?.nilIfEmpty,
            publishedAt: published.flatMap { formatter.date(from: $0) ?? rssFormatter.date(from: $0) },
            audioURL: audioURL?.nilIfEmpty,
            durationMs: duration.flatMap(FeedDuration.milliseconds(from:)),
            content: content?.nilIfEmpty,
            guid: guid?.nilIfEmpty,
            imageURL: [itunesImage, mediaThumbnail, mediaContentImage, enclosureImage].lazy
                .compactMap { $0.flatMap(httpsLink) }.first,
            enclosureURL: enclosure?.url,
            enclosureType: enclosure?.type,
            enclosureLengthBytes: enclosure?.length,
            publisherBlocked: blocked
        )
    }
}

/// Parses `itunes:duration`, which feeds write as `hh:mm:ss`, `mm:ss` or plain seconds.
enum FeedDuration {
    static func milliseconds(from value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let number = Double(part), number >= 0 else { return nil }
            seconds = seconds * 60 + number
        }
        guard seconds.isFinite, seconds > 0, seconds < 1_000_000 else { return nil }
        return Int((seconds * 1_000).rounded())
    }
}

/// The link when it is an https URL with a host, else nil.
private func httpsLink(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else { return nil }
    return trimmed
}

private func sanitize(_ value: String) -> String {
    value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Apple's `<itunes:block>Yes</itunes:block>` (#5340; https://podcasters.apple.com/support/823-podcast-requirements):
/// the publisher asks directories not to list the show, or one episode. Read by both feed parsers.
enum PublisherBlockSignal {
    static let appleNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd"

    /// `Yes` is the only value Apple gives a meaning; case and surrounding space are ignored. The element counts when its
    /// prefix is `itunes` as written (`FeedParser` does not process namespaces) or its namespace is Apple's (the
    /// resolver's parser does, so a feed that binds Apple's namespace to another prefix is still read).
    static func isBlock(_ qualifiedName: String, namespaceURI: String?, value: String) -> Bool {
        let parts = qualifiedName.lowercased().split(separator: ":")
        guard parts.last == "block" else { return false }
        let apple = (parts.count == 2 && parts[0] == "itunes") || namespaceURI?.lowercased() == appleNamespace
        return apple && value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes"
    }
}
