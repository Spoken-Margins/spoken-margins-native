#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A picture, embed or link an imported article carries, anchored to its place in the item's text (#2032).
///
/// The import used to drop all three: a picture line was removed and a link kept only its words. Timeline
/// shows these as rows (#1624), so the import keeps them here, apart from the text. `start` indexes the item's
/// canonical text in Characters, the same unit as a Margin's `startChar`, so the text itself is unchanged and
/// every Margin anchor stays where it was.
public struct SourceElement: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case picture, embed, link
    }

    public var id: String
    public var kind: Kind
    /// Where the element sits in the item's text: the start of the passage it belongs to, or of the words of a link.
    public var start: Int
    /// What the Timeline row says: a picture's caption (else its alt text, else "Picture"), an embed's service
    /// ("YouTube video"), or a link's own words.
    public var label: String
    /// The picture's alt text, kept apart from its caption for screen readers.
    public var altText: String?
    public var url: String

    public init(id: String, kind: Kind, start: Int, label: String, altText: String? = nil, url: String) {
        self.id = id
        self.kind = kind
        self.start = start
        self.label = label
        self.altText = altText
        self.url = url
    }
}

/// What the store keeps for one item. `textSHA256` ties the elements to the text their offsets index, so elements
/// saved for an earlier text are never applied to a different one.
public struct SourceElementsRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "source-elements.v1"

    public var schemaVersion: String
    public var textSHA256: String
    public var elements: [SourceElement]

    private struct Lossy: Decodable {
        let element: SourceElement?
        init(from decoder: Decoder) throws { element = try? SourceElement(from: decoder) }
    }

    /// An element this build can't read (a later phase's new kind) is skipped, not a reason to set the whole row
    /// aside as undecodable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        textSHA256 = try container.decode(String.self, forKey: .textSHA256)
        elements = try container.decode([Lossy].self, forKey: .elements).compactMap(\.element)
    }

    public init(text: String, elements: [SourceElement]) {
        schemaVersion = Self.currentSchemaVersion
        textSHA256 = Self.digest(of: text)
        self.elements = elements
    }

    /// The elements, when they were made for exactly this text.
    public func elements(for text: String) -> [SourceElement] {
        schemaVersion == Self.currentSchemaVersion && textSHA256 == Self.digest(of: text) ? elements : []
    }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol SourceElementsRepository {
    func saveSourceElements(_ record: SourceElementsRecord, itemId: String) throws
    func loadSourceElements(itemId: String) throws -> SourceElementsRecord?
}

/// Finds the pictures, embeds and links in the Markdown a readable page was captured as. The parser calls this
/// line by line while it cleans the text, so each element lands on the cleaned text it belongs to.
enum SourceElementCapture {
    struct Image: Equatable {
        var alt: String
        var url: String
    }

    struct Link: Equatable {
        var text: String
        var url: String
        /// The line's raw Markdown before the link, to find where its words fall once the line is cleaned.
        var precedingRaw: String
    }

    /// A line that is only a picture: `![alt](url)`. The page's own embeds (a video player) come through the
    /// same way, with an address that is a page, not an image.
    static func standaloneImage(_ line: String) -> Image? {
        guard let match = line.firstMatch(of: /^!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)$/),
              let url = webURL(String(match.2)) else { return nil }
        return Image(alt: String(match.1).trimmingCharacters(in: .whitespacesAndNewlines), url: url)
    }

    /// A line that is only a picture wrapped in a link: `[![alt](src)](page)`.
    static func linkedImage(_ line: String) -> Image? {
        guard let match = line.firstMatch(of: /^\[!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)\]\([^)]*\)$/),
              let url = webURL(String(match.2)) else { return nil }
        return Image(alt: String(match.1).trimmingCharacters(in: .whitespacesAndNewlines), url: url)
    }

    /// The words a picture carries as a caption: the paragraph right after it, when it is short and plain enough
    /// to be one. A page gives the caption as a bare paragraph, so this is a reading of the page, not a fact.
    static func caption(followingLine index: Int, in lines: [String]) -> String? {
        var next = index + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next += 1 }
        guard next < lines.count else { return nil }
        let candidate = lines[next].trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = cleanedLabel(candidate)
        guard !plain.isEmpty, plain.count <= maximumCaptionLength,
              candidate.range(of: #"^(?:#{1,6}\s|[-*+]\s|>|!\[|\[!\[|\||\d+[.)]\s|```)"#, options: .regularExpression) == nil,
              // A line that is only a link ("Read more") is a button or a pointer, not a caption.
              candidate.range(of: #"^\[[^\]]*\]\([^)]*\)$"#, options: .regularExpression) == nil
        else { return nil }
        return plain
    }

    /// Words from the page's Markdown as the cleaned text reads them: links keep their words, emphasis and code
    /// marks go, escapes are undone, entities and spacing are normalized the way the text is.
    static func cleanedLabel(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\([\\`*{}\[\]()#+\-.!_>])"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^[*_]+|[*_]+$"#, with: "", options: .regularExpression)
        return SpeechTextNormalizer.normalizeImportedText(value)
    }

    static let maximumCaptionLength = 140
    static let maximumLabelLength = 120

    static func kind(ofImageAt url: String) -> SourceElement.Kind {
        embedService(forURL: url) == nil ? .picture : .embed
    }

    /// Links in a line, each with the words it wraps. A picture is not a link, an in-page anchor, mail, phone
    /// or script address is not one a listener can follow, and neither is a button the page adds around the
    /// article (subscribe, share, comments).
    static func inlineLinks(in line: String) -> [Link] {
        let whole = NSRange(line.startIndex..., in: line)
        return linkExpression.matches(in: line, range: whole).compactMap { match in
            guard let matchRange = Range(match.range, in: line),
                  let textRange = Range(match.range(at: 1), in: line),
                  let urlRange = Range(match.range(at: 2), in: line) else { return nil }
            let text = String(line[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let url = webURL(String(line[urlRange])), !isPageChrome(url) else { return nil }
            return Link(text: text, url: url, precedingRaw: String(line[..<matchRange.lowerBound]))
        }
    }

    private static let linkExpression: NSRegularExpression = {
        // A literal pattern: it compiles, or the first test fails.
        try! NSRegularExpression(
            pattern: #"(?<!!)\[([^\]\[]+)\]\(\s*((?:[^()\s]|\([^()\s]*\))+)(?:\s+"[^"]*")?\s*\)"#)
    }()

    /// Where a link's words start in the cleaned `line`: right after the cleaned text that came before the link
    /// when the words are found there, else at their first occurrence at or after `searchFrom`, else nil.
    static func offset(of link: Link, words: String, in line: String, searchFrom: String.Index) -> (offset: Int, end: String.Index)? {
        guard !words.isEmpty else { return nil }
        // The line's own marker (heading, list, quote) is gone from the cleaned line.
        let raw = link.precedingRaw.replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|[-*+]\s+|>\s?)"#, with: "", options: .regularExpression)
        let before = cleanedLabel(raw)
        var expected = before.count
        if let last = raw.last, last.isWhitespace, !before.isEmpty { expected += 1 }
        if expected <= line.count {
            let from = line.index(line.startIndex, offsetBy: expected)
            if from >= searchFrom, line[from...].hasPrefix(words) {
                return (expected, line.index(from, offsetBy: words.count))
            }
        }
        guard let found = line.range(of: words, range: searchFrom..<line.endIndex) else { return nil }
        return (line.distance(from: line.startIndex, to: found.lowerBound), found.upperBound)
    }

    /// The address as an http(s) address, or nil for anything else.
    static func webURL(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard let components = URLComponents(string: cleaned),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return cleaned
    }

    private static func isPageChrome(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return true }
        let path = components.path.lowercased()
        let query = components.query?.lowercased() ?? ""
        return ["/subscribe", "/share", "/comments", "/signup", "/sign-in", "/account"].contains {
            path == $0 || path.hasPrefix($0 + "/")
        } || path.hasSuffix("/comments") || query.contains("action=share") || query.contains("action=subscribe")
    }

    /// A name for a page address whose host is a known video, audio or social service, else nil.
    static func embedService(forURL url: String) -> String? {
        guard var host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let services: [(hosts: [String], name: String)] = [
            (["youtube.com", "youtu.be", "youtube-nocookie.com", "m.youtube.com"], "YouTube video"),
            (["vimeo.com", "player.vimeo.com"], "Vimeo video"),
            (["spotify.com", "open.spotify.com"], "Spotify"),
            (["soundcloud.com"], "SoundCloud"),
            (["loom.com"], "Loom video"),
            (["twitter.com", "x.com"], "Post on X"),
            (["bsky.app"], "Bluesky post"),
            (["instagram.com"], "Instagram post"),
            (["tiktok.com"], "TikTok video"),
            (["podcasts.apple.com"], "Apple Podcasts"),
            (["bandcamp.com"], "Bandcamp"),
            (["twitch.tv"], "Twitch")
        ]
        return services.first { service in
            service.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }?.name
    }

    /// Whether the page is a Substack post: its own address, or pictures served from Substack's image host,
    /// which a publication on its own domain still uses. Phase 1 of #2032 covers these only.
    static func isSubstackPage(sourceURL: String, markdown: String) -> Bool {
        if let host = URLComponents(string: sourceURL)?.host?.lowercased(),
           host == "substack.com" || host.hasSuffix(".substack.com") {
            return true
        }
        return markdown.contains("substackcdn.com") || markdown.contains("substack-post-media")
    }

    static func shortened(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maximumLabelLength else { return collapsed }
        return String(collapsed.prefix(maximumLabelLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A picture's label: its caption, else its alt text, else "Picture". An alt text that is only a file name
    /// (Substack gives many pictures their upload name) says nothing, so it is not shown.
    static func pictureLabel(caption: String?, alt: String) -> String {
        if let caption, !caption.isEmpty { return shortened(caption) }
        return usableAlt(alt) == nil ? "Picture" : shortened(cleanedLabel(alt))
    }

    static func usableAlt(_ alt: String) -> String? {
        let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[\w\-. ]+\.(?:jpe?g|png|gif|webp|heic|svg)$"#, options: [.regularExpression, .caseInsensitive]) == nil,
              trimmed.range(of: #"^(?:image|img|screenshot|photo)[ _\-]?\d*$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return trimmed
    }

    /// Keeps one row per address (the first), in text order, and numbers them.
    static func finalized(_ elements: [SourceElement], textLength: Int) -> [SourceElement] {
        var seenLinks = Set<String>()
        var seenPictures = Set<String>()
        var kept: [SourceElement] = []
        let ordered = elements.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        for element in ordered {
            switch element.kind {
            case .link:
                guard seenLinks.insert(element.url).inserted else { continue }
            case .picture, .embed:
                guard seenPictures.insert(element.url).inserted else { continue }
            }
            var copy = element
            copy.start = min(max(0, element.start), textLength)
            copy.id = String(format: "e%05d", kept.count)
            kept.append(copy)
        }
        return kept
    }
}
