import Foundation
import SessionKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #4341: what a listener pastes into "Follow papers". One recognizer for both providers, so the field can teach
// where each link lives and every other link still goes to today's feed follow. It reads the text only: no request is
// made and nothing is stored.

extension PaperSource {
    /// The address to fetch the list's first page from (Zotero: `items/top`, newest joined first, 100 papers a page;
    /// PubMed: the RSS).
    public func pageURL(start: Int = 0) -> URL {
        switch self {
        case .zoteroGroup(let groupID, let collectionKey):
            return ZoteroPaperAPI.itemsURL(groupID: groupID, collectionKey: collectionKey, start: start)
        case .zoteroUser(let userID, let collectionKey):
            return ZoteroPaperAPI.itemsURL(library: .user(userID), collectionKey: collectionKey, start: start)
        case .pubMedRSS(let token, let limit):
            var components = URLComponents()
            components.scheme = "https"
            components.host = PaperFeedLink.pubMedHost
            components.path = "/rss/search/\(token)/"
            if let limit { components.queryItems = [URLQueryItem(name: "limit", value: String(limit))] }
            return components.url!
        }
    }
}

/// Zotero's web API, read-only here. Every request sends `Zotero-API-Version: 3` and pages by 100. Only a request for the
/// listener's own library carries their key (`ZoteroPaperAPI.request`), and only to this host.
public enum ZoteroPaperAPI {
    public static let host = "api.zotero.org"
    public static let pageSize = 100
    public static let requestHeaders = ["Zotero-API-Version": "3"]
    /// The header the key travels in. It is never put in an address, so no log line that prints an address holds it.
    public static let keyHeader = "Zotero-API-Key"

    /// A public group's library, or the listener's own.
    public enum Library: Equatable, Sendable {
        case group(Int)
        case user(Int)

        var pathPrefix: String {
            switch self {
            case .group(let id): return "/groups/\(id)"
            case .user(let id): return "/users/\(id)"
            }
        }
    }

    /// The papers of a library or collection: top-level items only, so an attachment or note is not a paper. Newest
    /// joined first, so the 500 a list keeps are the newest.
    public static func itemsURL(groupID: Int, collectionKey: String?, start: Int = 0) -> URL {
        itemsURL(library: .group(groupID), collectionKey: collectionKey, start: start)
    }

    public static func itemsURL(library: Library, collectionKey: String?, start: Int = 0) -> URL {
        listURL(
            library: library, collectionKey: collectionKey, tail: "/items/top",
            extra: [URLQueryItem(name: "sort", value: "dateAdded"), URLQueryItem(name: "direction", value: "desc")],
            start: start
        )
    }

    /// The attachments of the same list. A paper's PDF is one of these, found by its `parentItem`.
    public static func attachmentsURL(groupID: Int, collectionKey: String?, start: Int = 0) -> URL {
        attachmentsURL(library: .group(groupID), collectionKey: collectionKey, start: start)
    }

    public static func attachmentsURL(library: Library, collectionKey: String?, start: Int = 0) -> URL {
        listURL(
            library: library, collectionKey: collectionKey, tail: "/items",
            // Newest first like the papers, so in a library past the 1,000-attachment read the PDFs left out are the
            // ones of the oldest papers, which the 500-paper list has already dropped.
            extra: [URLQueryItem(name: "itemType", value: "attachment"), URLQueryItem(name: "sort", value: "dateAdded"),
                    URLQueryItem(name: "direction", value: "desc")],
            start: start
        )
    }

    /// A library's collections, for "Your collections" (the listener's own library only).
    public static func collectionsURL(library: Library, start: Int = 0) -> URL {
        listURL(library: library, collectionKey: nil, tail: "/collections", extra: [], start: start)
    }

    /// One collection's own record, which carries its name.
    public static func collectionURL(library: Library, collectionKey: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = library.pathPrefix + "/collections/\(collectionKey)"
        components.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components.url!
    }

    /// A group's own record, which carries its name.
    public static func groupURL(groupID: Int) -> URL {
        URL(string: "https://\(host)/groups/\(groupID)")!
    }

    /// A stored file of the listener's own library.
    public static func fileURL(userID: Int, attachmentKey: String) -> URL {
        URL(string: "https://\(host)/users/\(userID)/items/\(attachmentKey)/file")!
    }

    /// The request for one Zotero address: the version header always, the key only for the listener's own library and
    /// only when the address is on Zotero's API host.
    public static func request(_ url: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        for (name, value) in requestHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let apiKey, !apiKey.isEmpty, url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
           url.path.hasPrefix("/users/") {
            request.setValue(apiKey, forHTTPHeaderField: keyHeader)
        }
        return request
    }

    /// A redirect from a key-carrying request (a stored file is served from another host): the key header stays only
    /// on Zotero's own API host, and a hop that leaves https is refused.
    public static func redirectRequest(_ proposed: URLRequest) -> URLRequest? {
        guard let url = proposed.url, url.scheme?.lowercased() == "https" else { return nil }
        var request = proposed
        if url.host?.lowercased() != host { request.setValue(String?.none, forHTTPHeaderField: keyHeader) }
        return request
    }

    private static func listURL(library: Library, collectionKey: String?, tail: String, extra: [URLQueryItem], start: Int) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = library.pathPrefix + (collectionKey.map { "/collections/\($0)" } ?? "") + tail
        components.queryItems = extra + [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "start", value: String(max(0, start)))
        ]
        return components.url!
    }
}

/// Why a pasted link can't be followed, in the words the field shows under it (the Design for #4341).
public enum PaperFeedLinkProblem: Equatable, Sendable {
    /// A PubMed results page, not the RSS link its Create RSS button makes.
    case pubMedSearchPage
    /// A Zotero user library: it is followed from Your collections once the listener connects it in Settings.
    case zoteroPrivateLibrary
    /// A zotero.org address that isn't a group library or collection, or whose collection key is malformed.
    case zoteroNotUnderstood

    /// The words with no library connected.
    public var message: String { message(zoteroConnected: false) }

    public func message(zoteroConnected: Bool) -> String {
        switch self {
        case .pubMedSearchPage:
            return "That's a PubMed search page. Use its Create RSS link instead."
        case .zoteroPrivateLibrary:
            return zoteroConnected
                ? "That Zotero library is private. Follow it from Your collections."
                : "That Zotero library is private. Connect your library in Settings to follow it."
        case .zoteroNotUnderstood:
            return "Zotero couldn't find that collection. Check the link."
        }
    }
}

public enum PaperFeedLink: Equatable, Sendable {
    /// A reading list to follow as papers.
    case source(PaperSource)
    /// A Zotero or PubMed link that can't be followed, with the reason to show.
    case rejected(PaperFeedLinkProblem)
    /// Not a paper link: the existing feed follow takes it, exactly as before.
    case notAPaperLink

    static let pubMedHost = "pubmed.ncbi.nlm.nih.gov"
    static let longestLink = 2_048

    /// Reads what the listener pasted. Never fetches. Case of the host, a missing `https://`, `http://`, a trailing
    /// slash, `www.`, extra query parameters, a Unicode group name and surrounding spaces don't change the answer.
    /// A link with a user name, a port other than 443, another scheme or a lookalike host is not a paper link.
    public static func recognize(_ pasted: String) -> PaperFeedLink {
        guard let link = ParsedLink(pasted) else { return .notAPaperLink }
        switch link.host {
        case "zotero.org", "www.zotero.org", ZoteroPaperAPI.host:
            return recognizeZotero(link)
        case pubMedHost:
            return recognizePubMed(link)
        case "www.ncbi.nlm.nih.gov", "ncbi.nlm.nih.gov":
            // The old address of a PubMed search page. Nothing else on ncbi.nlm.nih.gov is ours.
            guard link.segments.first?.lowercased() == "pubmed", link.segments.count == 1, link.query["term"] != nil
            else { return .notAPaperLink }
            return .rejected(.pubMedSearchPage)
        default:
            return .notAPaperLink
        }
    }

    // MARK: Zotero

    /// Words that follow the group in a web address and are never its name.
    private static let filterParameters: Set<String> = ["q", "qmode", "tag", "itemtype", "itemkey"]

    private static let zoteroSections: Set<String> = ["collections", "items", "library", "tags", "search", "settings", "members"]

    private static func recognizeZotero(_ link: ParsedLink) -> PaperFeedLink {
        let segments = link.segments
        // The site's own pages (its blog feed, downloads, support) are not lists, and the existing follow may know them.
        guard let first = segments.first?.lowercased() else { return .notAPaperLink }
        if first == "users" { return .rejected(.zoteroPrivateLibrary) }
        if first != "groups" {
            // zotero.org/<username>/library, /items or /collections is a person's own library.
            if segments.count >= 2, ["library", "items", "collections"].contains(segments[1].lowercased()) {
                return .rejected(.zoteroPrivateLibrary)
            }
            return .notAPaperLink
        }
        // A filter in an API address would follow a different list than the one pasted.
        if !link.query.keys.allSatisfy({ !filterParameters.contains($0.lowercased()) }) { return .rejected(.zoteroNotUnderstood) }
        guard segments.count >= 2, segments[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let groupID = Int(segments[1]), groupID > 0
        else { return .rejected(.zoteroNotUnderstood) }
        var rest = Array(segments.dropFirst(2))
        // zotero.org/groups/<id>/<name>/...: the name is for people to read and is dropped.
        if let head = rest.first, !zoteroSections.contains(head.lowercased()) { rest.removeFirst() }
        var index = 0
        while index < rest.count {
            switch rest[index].lowercased() {
            case "collections":
                guard index + 1 < rest.count, isZoteroKey(rest[index + 1]) else { return .rejected(.zoteroNotUnderstood) }
                // Anything after the key (`items/<key>/library`, `items/top`) narrows a view, not the list.
                return .source(.zoteroGroup(groupID: groupID, collectionKey: rest[index + 1]))
            case "items":
                // `items/<key>` is one paper open in the whole library and `items/top` is the API's own list.
                index += 1
                if index < rest.count, rest[index].lowercased() == "top" || isZoteroKey(rest[index]) { index += 1 }
            case "library":
                index += 1
            default:
                // `tags/...`, `search/...` and the like would follow a different list than the one shown.
                return .rejected(.zoteroNotUnderstood)
            }
        }
        return .source(.zoteroGroup(groupID: groupID, collectionKey: nil))
    }

    /// Zotero keys are eight upper-case letters and digits.
    private static func isZoteroKey(_ text: String) -> Bool {
        text.count == 8 && text.utf8.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }
    }

    // MARK: PubMed

    private static func recognizePubMed(_ link: ParsedLink) -> PaperFeedLink {
        let segments = link.segments
        if segments.count == 3, segments[0].lowercased() == "rss", segments[1].lowercased() == "search" {
            let token = segments[2]
            guard !token.isEmpty, token.utf8.allSatisfy({ isTokenByte($0) }) else { return .notAPaperLink }
            var limit: Int?
            if let text = link.query["limit"], let value = Int(text), (1...100).contains(value) { limit = value }
            return .source(.pubMedRSS(token: token, limit: limit))
        }
        // A results page: the address bar of a search. A paper's own page (`/<pmid>/`) is not a feed.
        if segments.isEmpty, link.query["term"] != nil { return .rejected(.pubMedSearchPage) }
        return .notAPaperLink
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2D || byte == 0x5F
    }
}

/// The parts of a pasted address the recognizer reads. Built by hand so that a Unicode group name, which
/// `URL(string:)` refuses on some platforms, doesn't change the answer.
private struct ParsedLink {
    var host: String
    var segments: [String]
    var query: [String: String]

    init?(_ pasted: String) {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= PaperFeedLink.longestLink,
              !text.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        let beforePath = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if beforePath.hasSuffix(":"), text.dropFirst(beforePath.count).hasPrefix("//"), let schemeEnd = text.range(of: "://") {
            let scheme = text[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            text = String(text[schemeEnd.upperBound...])
        } else if text.contains(":") && !Self.hostLooksLikeAuthority(text) {
            return nil  // `zotero://...`, `mailto:...`
        }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        var queryText = ""
        if let mark = text.firstIndex(of: "?") {
            queryText = String(text[text.index(after: mark)...])
            text = String(text[..<mark])
        }
        let authority: String
        let path: String
        if let slash = text.firstIndex(of: "/") {
            authority = String(text[..<slash])
            path = String(text[slash...])
        } else {
            authority = text
            path = ""
        }
        guard !authority.contains("@") else { return nil }
        var hostText = authority
        if let colon = authority.lastIndex(of: ":") {
            guard authority[authority.index(after: colon)...] == "443" else { return nil }
            hostText = String(authority[..<colon])
        }
        while hostText.hasSuffix(".") { hostText.removeLast() }
        guard !hostText.isEmpty else { return nil }
        host = hostText.lowercased()
        segments = path.split(separator: "/", omittingEmptySubsequences: true).map { Self.unescaped(String($0)) }
        var pairs: [String: String] = [:]
        for part in queryText.split(separator: "&", omittingEmptySubsequences: true) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = Self.unescaped(String(pair[0]).replacingOccurrences(of: "+", with: " "))
            guard !name.isEmpty, pairs[name] == nil else { continue }
            pairs[name] = pair.count > 1 ? Self.unescaped(String(pair[1]).replacingOccurrences(of: "+", with: " ")) : ""
        }
        query = pairs
    }

    /// `host:443/path` has a colon but no scheme. Anything else with a colon before the first slash is a scheme.
    private static func hostLooksLikeAuthority(_ text: String) -> Bool {
        let head = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let colon = head.lastIndex(of: ":") else { return true }
        let port = head[head.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy(\.isNumber)
    }

    private static func unescaped(_ text: String) -> String { text.removingPercentEncoding ?? text }
}
