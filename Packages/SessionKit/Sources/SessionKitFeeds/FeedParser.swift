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
}

public struct ParsedFeed: Equatable, Sendable {
    public var format: ParsedFeedFormat
    public var title: String
    public var homePageURL: String?
    public var feedURL: String?
    public var items: [ParsedFeedItem]
}

public enum FeedParserError: Error, LocalizedError, Equatable {
    case responseTooLarge
    case malformed
    case tooDeep
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "The feed exceeds the 16 MB safety limit."
        case .malformed: return "The feed is malformed."
        case .tooDeep: return "The feed XML nesting exceeds the safety limit."
        case .unsupported: return "The response is not RSS, Atom, or JSON Feed."
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
            items: Array(delegate.items.prefix(limits.maximumEntries))
        )
    }

    private func parseJSON(_ data: Data) throws -> ParsedFeed {
        struct JSONFeed: Decodable {
            struct Item: Decodable {
                struct Attachment: Decodable { var url: String; var mime_type: String? }
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
            }
            struct Author: Decodable { var name: String? }
            var version: String
            var title: String
            var home_page_url: String?
            var feed_url: String?
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
            let author = item.authors?.compactMap(\.name).joined(separator: ", ").nilIfEmpty ?? item.author?.name
            return ParsedFeedItem(
                id: item.id ?? url,
                title: sanitize(item.title ?? "Untitled"),
                url: url,
                author: author.map(sanitize),
                summary: rawSummary.map(sanitize),
                publishedAt: item.date_published.flatMap(formatter.date(from:)),
                audioURL: audio
            )
        }
        return ParsedFeed(format: .json, title: sanitize(decoded.title), homePageURL: decoded.home_page_url, feedURL: decoded.feed_url, items: items)
    }
}

private final class XMLFeedDelegate: NSObject, XMLParserDelegate {
    let limits: FeedParserLimits
    var format: ParsedFeedFormat?
    var feedTitle = ""
    var homePageURL = ""
    var feedURL = ""
    var items: [ParsedFeedItem] = []
    var tooDeep = false
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
        if format == .atom, name == "link", let href = attributeDict["href"] {
            let rel = attributeDict["rel"] ?? "alternate"
            if inEntry {
                if rel == "alternate" { item?.url = href }
                if rel == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("audio/") { item?.audioURL = href }
            } else if rel == "self" { feedURL = href } else if rel == "alternate" { homePageURL = href }
        }
        if format == .rss, name == "enclosure", (attributeDict["type"] ?? "").lowercased().hasPrefix("audio/") {
            item?.audioURL = attributeDict["url"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = normalized(qName ?? elementName)
        let value = sanitize(text)
        if inEntry {
            switch name {
            case "title": item?.title = value
            case "link": if format == .rss && item?.url == nil { item?.url = value }
            case "guid", "id": item?.id = value
            case "description", "summary", "content", "encoded": item?.summary = value
            case "author", "creator", "name": if item?.author == nil { item?.author = value }
            case "pubdate", "published", "updated": item?.published = value
            default: break
            }
        } else {
            if name == "title", feedTitle.isEmpty { feedTitle = value }
            if name == "link", format == .rss, homePageURL.isEmpty { homePageURL = value }
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
    var title: String?
    var url: String?
    var author: String?
    var summary: String?
    var published: String?
    var audioURL: String?
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
            audioURL: audioURL?.nilIfEmpty
        )
    }
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
