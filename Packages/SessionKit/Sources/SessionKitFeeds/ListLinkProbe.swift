import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a pasted or typed link points at (#4046 PR 6): the Follow sheet follows a feed as it always did and opens a list's
/// preview. One GET, anonymous, read only as far as the first element.
public enum ListLinkProbe {
    public enum Kind: Equatable, Sendable {
        /// The reply's root element is `<opml>`.
        case list
        /// An RSS, Atom or JSON feed.
        case feed
        /// Anything else that answered: HTML, another kind of XML, JSON that isn't a feed, an empty reply.
        case page
        /// Offline, a timeout, a refused connection, a bad redirect or an error status.
        case unreachable
    }

    /// A reply is read whole by the session before it is looked at, so this only keeps an absurd one out of memory. A list
    /// over its own limits is still a list: the preview says it is too big.
    static let maximumBytes = 16 * 1_024 * 1_024
    static let accept = "text/x-opml, application/xml, text/xml, application/rss+xml, application/atom+xml, application/feed+json, application/json, text/html;q=0.5, */*;q=0.1"

    public static func probe(_ url: URL, session: URLSession) async -> Kind {
        do {
            let reply = try await ListLinkTransport.get(url, accept: accept, maximumBytes: maximumBytes, session: session)
            guard (200..<300).contains(reply.status) else { return .unreachable }
            return classify(reply.data)
        } catch {
            return .unreachable
        }
    }

    /// The kind of a reply body, from its root element (XML) or its `version` (JSON Feed).
    static func classify(_ data: Data) -> Kind {
        let head = String(decoding: data.prefix(8_192), as: UTF8.self)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .lowercased()
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .page }
        if trimmed.hasPrefix("{") {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let version = object["version"] as? String, version.contains("jsonfeed.org") else { return .page }
            return .feed
        }
        guard let element = rootElementName(in: trimmed) else { return .page }
        switch element {
        case "opml": return .list
        case "rss", "feed", "rdf:rdf", "rdf": return .feed
        default: return .page
        }
    }

    /// The first element's name, past the XML declaration, comments, processing instructions and an XML doctype. An HTML
    /// doctype is a page.
    private static func rootElementName(in text: String) -> String? {
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "<") {
            let after = text.index(after: open)
            guard after < text.endIndex else { return nil }
            let rest = text[after...]
            if rest.hasPrefix("?") || rest.hasPrefix("!--") {
                let closer = rest.hasPrefix("?") ? "?>" : "-->"
                guard let end = text.range(of: closer, range: after..<text.endIndex) else { return nil }
                index = end.upperBound
                continue
            }
            if rest.hasPrefix("!") {
                if rest.hasPrefix("!doctype html") { return "html" }
                // An XML doctype, possibly with an internal subset in brackets.
                guard let end = text[after...].firstIndex(of: ">") else { return nil }
                index = text.index(after: end)
                continue
            }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "_" || $0 == "-" || $0 == "." }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }
}
