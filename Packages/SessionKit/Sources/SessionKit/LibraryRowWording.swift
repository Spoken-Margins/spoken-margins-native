import Foundation

/// #359: the words a Library row uses for what an item is and where it came from.
/// A row used to show the stored media type ("Transcript Backed Media") and a raw
/// URL as its byline, and the two PDF readers differed only by an unlabelled icon.
public enum LibraryRowWording {
    /// The kind the Library filter sorts an item under.
    public static func contentType(
        mediaType: String,
        sourceReference: String?,
        sourceReferenceType: String?
    ) -> LibraryContentTypeFilter {
        if sourceReference?.lowercased().contains(".pdf") == true { return .pdf }
        switch mediaType.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "article", TargetType.browserOwnedMedia.rawValue: return .article
        case "podcast", TargetType.transcriptBackedMedia.rawValue: return .podcast
        case "audiobook": return .audiobook
        default:
            return sourceReferenceType == "url" ? .article : .text
        }
    }

    /// The kind in words, matching the Library filter's names so a listener can
    /// filter by what a row says. `usesNewReader` marks a PDF read through the
    /// structured-document reader, so it can be told apart from an older import
    /// of the same file.
    public static func kindLabel(
        mediaType: String,
        sourceReference: String?,
        sourceReferenceType: String?,
        usesNewReader: Bool
    ) -> String {
        if mediaType.lowercased() == "guided_tour" { return "Guided tour" }
        switch contentType(mediaType: mediaType, sourceReference: sourceReference, sourceReferenceType: sourceReferenceType) {
        case .pdf:
            // The app reads a PDF through the new reader only when it's stored as "pdf".
            return usesNewReader && mediaType.lowercased() == "pdf" ? "PDF, new reader" : "PDF"
        case .epub: return "EPUB"
        case .article: return "Article"
        case .podcast: return "Podcast"
        case .audiobook: return "Audiobook"
        case .text, .all: return "Text"
        }
    }

    /// Who or where an item is from, or nil when there's nothing worth showing.
    /// A web address shows as its site ("arxiv.org"), never as the raw URL.
    public static func byline(sourceTitle: String?, author: String?, title: String) -> String? {
        for candidate in [sourceTitle, author] {
            guard var value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if value.hasPrefix("[["), value.hasSuffix("]]") {
                value = String(value.dropFirst(2).dropLast(2))
            }
            if isAddress(value) {
                guard let site = webSiteName(value) else { continue }
                value = site
            }
            if value.caseInsensitiveCompare(title) != .orderedSame { return value }
        }
        return nil
    }

    /// A URL of any scheme ("https://…", "file://…", "bundled://…") or a bare "www." address.
    private static func isAddress(_ value: String) -> Bool {
        !value.contains(" ") && (value.contains("://") || value.lowercased().hasPrefix("www."))
    }

    /// The Library row's count of the listener's own Margins: "1 Margin", "3 Margins". Nil for none, so a row with
    /// no Margins stays quiet (#2394). The words carry it; the row adds an icon, never a colour alone.
    public static func marginCountLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 Margin" : "\(count) Margins"
    }

    /// The site of a web address, without "www."; nil for any other kind of address.
    private static func webSiteName(_ value: String) -> String? {
        let lowered = value.lowercased()
        let web = lowered.hasPrefix("www.") ? "https://\(value)" : value
        guard lowered.hasPrefix("www.") || lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
              let host = URL(string: web)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// A Library row's detail line, split so the item's length never truncates (#305 audit).
/// The row shows `length` in its own text with room kept for it, then `rest` on the same line,
/// which is what gives way to a long byline or status.
public struct LibraryRowDetail: Equatable, Sendable {
    /// "about 25 min" for a text item; nil when there's no length to show (podcasts).
    public let length: String?
    /// The byline, kind, listening progress and status, joined with " · ".
    public let rest: String

    public init(byline: String?, kind: String, length: String?, listening: String?, status: String?) {
        self.length = Self.nonEmpty(length)
        rest = [byline, kind, listening, status].compactMap(Self.nonEmpty).joined(separator: Self.separator)
    }

    /// The whole line as one string, for sizes where the row wraps instead of truncating.
    public var fullLine: String {
        [length, rest].compactMap(Self.nonEmpty).joined(separator: Self.separator)
    }

    /// The text that follows the length on the line: " · " and the rest, or nothing.
    public var restAfterLength: String {
        guard length != nil, !rest.isEmpty else { return rest }
        return Self.separator + rest
    }

    static let separator = " · "

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
