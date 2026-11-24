import Foundation
import SessionKit

/// #4858: what an import preview row shows for a feed. A feed that came in with a name shows it. One that came
/// in without (a Shortcut that passed only the Feed URL, an OPML outline with no text) never shows its whole
/// URL, which a listener can't tell apart from a hundred others: it shows the host, then the last part of the
/// path when that part is short and means something ("feeds.simplecast.com/the-daily").
public struct FeedDisplayName: Equatable, Sendable {
    public var text: String
    /// False when no name was passed in and `text` is made from the address.
    public var hasName: Bool

    /// - Parameters:
    ///   - title: the feed's title as the parser gave it. Both parsers use the feed URL itself as the title of a
    ///     nameless row, so a title equal to `feedURL` (or blank) counts as no name.
    ///   - feedURL: the link the row was read from.
    public init(title: String, feedURL: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !Self.isAddress(trimmed, of: feedURL) {
            self.init(text: trimmed, hasName: true)
        } else {
            self.init(text: Self.readableAddress(feedURL), hasName: false)
        }
    }

    public init(text: String, hasName: Bool) {
        self.text = text
        self.hasName = hasName
    }

    /// True when `title` is the feed's own address: the same text, or the same feed once scheme and host case,
    /// http against https and a trailing slash are ignored (`FeedURLKey`). The planner offers an http feed
    /// over https, so a nameless row's title (the http link) and its candidate's URL (https) differ as text.
    static func isAddress(_ title: String, of feedURL: String) -> Bool {
        let url = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if title == url { return true }
        guard let titleKey = FeedURLKey.make(title), let urlKey = FeedURLKey.make(url) else { return false }
        return titleKey == urlKey
    }

    /// The longest last path part kept in a readable address.
    public static let longestPathPart = 28
    /// A part made only of hex digits and dashes this long or longer reads as an id or hash and is dropped.
    public static let idLength = 12
    static let fileExtensions = ["xml", "rss", "atom", "json"]
    static let plumbingWords: Set<String> = ["feed", "feeds", "rss", "atom", "index", "podcast", "podcasts", "xml"]

    /// The host, lowercased, plus "/" and the last non-empty path part when it is meaningful; the host alone
    /// otherwise. Falls back to the trimmed text for something that is not a URL with a host.
    public static func readableAddress(_ feedURL: String) -> String {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let rawHost = components.host, !rawHost.isEmpty else { return trimmed }
        let host = rawHost.lowercased()
        guard let part = meaningfulPathPart(components.percentEncodedPath) else { return host }
        return "\(host)/\(part)"
    }

    /// The last non-empty part of a percent-encoded path, decoded, with a feed file extension removed; nil when
    /// it is too long, only digits, an id, or a plumbing word such as "feed" or "rss". Splitting before decoding
    /// keeps an encoded "/" inside the part.
    static func meaningfulPathPart(_ path: String) -> String? {
        guard let last = path.split(separator: "/").last.map(String.init) else { return nil }
        var part = last.removingPercentEncoding ?? last
        if let dot = part.lastIndex(of: "."), fileExtensions.contains(part[part.index(after: dot)...].lowercased()) {
            part = String(part[..<dot])
        }
        guard !part.isEmpty, part.count <= longestPathPart,
              !plumbingWords.contains(part.lowercased()),
              !part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let idCharacters = Set("0123456789abcdefABCDEF-")
        if part.count >= idLength, part.allSatisfy({ idCharacters.contains($0) }) { return nil }
        return part
    }
}

/// #4858: whether a feed's host is on the listener's own network (a NAS, a home server). Such an address will
/// rarely work away from home, so the import preview marks it and leaves it unticked. Plain http on a public
/// host is not marked: the app tries it over https and a failure shows with its reason.
public enum FeedHostClass {
    /// True for `localhost`, a `.local` name, a name with no dot (`nas`), and private, loopback and link-local
    /// addresses: 10/8, 172.16/12, 192.168/16, 127/8, 169.254/16, `::1`, fc00::/7 and fe80::/10.
    public static func isHomeNetwork(host rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") { return ipv6(host).map(isHomeNetworkIPv6) ?? false }
        if let octets = ipv4(host) { return isHomeNetworkIPv4(octets) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        return !host.contains(".")
    }

    /// The host of `url`, checked as above; false for nil or a URL with no host.
    public static func isHomeNetwork(url: String?) -> Bool {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return false }
        return isHomeNetwork(host: host)
    }

    static func isHomeNetworkIPv4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    static func isHomeNetworkIPv6(_ groups: [UInt16]) -> Bool {
        if groups == [0, 0, 0, 0, 0, 0, 0, 1] { return true }
        if groups[0] & 0xFE00 == 0xFC00 { return true }
        if groups[0] & 0xFFC0 == 0xFE80 { return true }
        // An IPv4-mapped address (::ffff:192.168.1.10) is the IPv4 address inside it.
        if groups[0..<5].allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return isHomeNetworkIPv4([UInt8(groups[6] >> 8), UInt8(groups[6] & 0xFF), UInt8(groups[7] >> 8), UInt8(groups[7] & 0xFF)])
        }
        return false
    }

    /// Four dotted decimal octets, each 0 to 255; nil for anything else (a name such as `10.example.com`).
    static func ipv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return UInt8(part)
        }
        return octets.count == 4 ? octets : nil
    }

    /// The eight groups of an IPv6 address, with `::` expanded and a trailing dotted IPv4 part read; nil when
    /// it is not one.
    static func ipv6(_ host: String) -> [UInt16]? {
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ text: String) -> [UInt16]? {
            guard !text.isEmpty else { return [] }
            var result: [UInt16] = []
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, piece.contains("."), let v4 = ipv4(String(piece)) {
                    result.append(UInt16(v4[0]) << 8 | UInt16(v4[1]))
                    result.append(UInt16(v4[2]) << 8 | UInt16(v4[3]))
                    continue
                }
                guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }
        guard let head = groups(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }
}
