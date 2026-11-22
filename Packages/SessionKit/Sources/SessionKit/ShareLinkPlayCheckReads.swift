import Foundation

/// What the sender's play check may ask the app to read for the web page (#4454, PR 3), and what it says about itself.
///
/// The page runs inside the app's hidden web view. It cannot read a publisher's page (CORS), and our relay must never
/// see the item's address, so it asks the app: one read of a Substack post's page and the first 1 KB of the episode's
/// audio, once per link (the owner's yes, 2026-11-17). This file decides which asks are allowed; the app's web view does
/// the reading. Nothing here touches the network.
extension ShareLinkPlayCheck {
    /// The most of a post's page the app returns, as `Web/src/sources/read.ts` allows itself.
    public static let maximumPageBytes = 4 * 1024 * 1024
    /// The audio's first bytes: enough to see the status and the type, never the episode.
    public static let audioStartBytes = 1_024

    /// One ask from the page (`Web/src/app/play-check-reads.ts`): `{ kind: 'page' | 'audio-start', url }`.
    public enum ReadRequest: Equatable, Sendable {
        case page(URL)
        case audioStart(URL)

        public var url: URL {
            switch self {
            case .page(let url), .audioStart(let url): url
            }
        }

        /// Reads an ask, or nil for anything else: an unknown kind, no address, or an address the app will not read.
        public init?(body: Any) {
            guard let dictionary = body as? [String: Any],
                  let kind = dictionary["kind"] as? String,
                  let raw = dictionary["url"] as? String, raw.utf8.count <= 2_048,
                  let url = URL(string: raw), Self.isReadableAddress(url) else { return nil }
            switch kind {
            case "page":
                // Only a Substack post's page: the one read that was agreed. Any other page stays unchecked.
                guard Self.isSubstackPostAddress(url) else { return nil }
                self = .page(url)
            case "audio-start":
                self = .audioStart(url)
            default:
                return nil
            }
        }

        /// A public https address with a name: no sign-in in it, no unusual port, no address of this phone or its network.
        public static func isReadableAddress(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host?.lowercased(), !host.isEmpty else { return false }
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
            // An address of the phone's own network is not a publisher: a name has a letter, an address has digits and dots or colons.
            if host.contains(":") { return false }
            // Including the spellings CFNetwork also resolves as an address: `0x7f.0.0.1`, `2130706433`, `0177.0.0.1`.
            let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.allSatisfy({ $0.hasPrefix("0x") || (!$0.isEmpty && $0.allSatisfy(\.isNumber)) }) { return false }
            return host.contains(".")
        }

        /// `/p/<slug>` on any host, or a `substack.com` address with `/p/<slug>` in its path (as `Web/src/sources/substack.ts`).
        static func isSubstackPostAddress(_ url: URL) -> Bool {
            let path = url.path
            var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if segments.last == "" { segments.removeLast() }
            if segments.count == 3, segments[0] == "", segments[1] == "p", !segments[2].isEmpty { return true }
            let host = url.host?.lowercased() ?? ""
            let onSubstack = host == "substack.com" || host.hasSuffix(".substack.com")
            return onSubstack && path.range(of: #"/p/[^/]"#, options: .regularExpression) != nil
        }
    }

    /// One page and one audio start for each check, and no more: a page that asks twice, or asks for a second post, is
    /// refused.
    public struct ReadBudget: Equatable, Sendable {
        private var pageRead = false
        private var audioRead = false

        public init() {}

        /// Whether the app may make this read. A read that is allowed is spent.
        public mutating func allow(_ request: ReadRequest) -> Bool {
            switch request {
            case .page:
                guard !pageRead else { return false }
                pageRead = true
            case .audioStart:
                guard !audioRead else { return false }
                audioRead = true
            }
            return true
        }
    }

    // MARK: - Which link, and what Diagnostics may say

    /// The key a link's check is kept under: its host and path, never its fragment (the key) or query.
    public static func linkID(for link: URL) -> String? {
        guard let host = link.host?.lowercased(), !host.isEmpty, link.path.hasPrefix("/l/") else { return nil }
        return host + link.path
    }

    /// A short code for an outcome. It names a reason, never a link, title or address.
    public static func code(for outcome: Outcome) -> String {
        switch outcome {
        case .checking: "checking"
        case .plays: "plays"
        case .problem(let reason): "problem.\(reason.rawValue)"
        case .notChecked(.offline): "not-checked.offline"
        case .notChecked(.lowDataMode): "not-checked.low-data"
        case .notChecked(.didNotFinish): "not-checked.did-not-finish"
        case .notChecked(.postVoiceNotLookedUp): "not-checked.post-voice"
        case .gone: "gone"
        }
    }

    /// The packet's size, in a bucket: enough to see whether big packets are the slow ones, not the packet.
    public static func packetSizeBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<(1 << 20): "under-1mb"
        case ..<(5 << 20): "1-5mb"
        case ..<(20 << 20): "5-20mb"
        default: "over-20mb"
        }
    }

    /// The Diagnostics line for a finished check: a code, milliseconds and a size bucket. Never a URL, id or title.
    public static func diagnosticFields(for outcome: Outcome, milliseconds: Int, packetBytes: Int) -> [String: String] {
        ["outcome": code(for: outcome), "ms": String(max(0, milliseconds)), "packet": packetSizeBucket(packetBytes)]
    }
}
