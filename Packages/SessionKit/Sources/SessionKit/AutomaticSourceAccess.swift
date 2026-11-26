import Foundation

/// Which of an episode's access links may leave the device on their own: in a packet (sent as a file or by link),
/// the share sheet's link, a Markdown export or a community map upload (#5340).
///
/// `ShareableLinkPolicy` (#168) already drops a link that itself holds a secret. This adds what is known about where
/// the episode came from, so an ordinary-looking audio link is withheld too when:
/// - its feed asked directories not to list it: Apple's `<itunes:block>Yes</itunes:block>` on the episode or the whole
///   show (https://podcasters.apple.com/support/823-podcast-requirements). A restriction signal, not proof of privacy;
/// - it came from a feed whose own address holds an access secret (a paid or credentialed feed), recorded as the item's
///   `sourceURL` or, where the feed address is not kept, as `fromPrivateFeed`.
///
/// Only the item's audio link and feed link are withheld, and anything that is one of them (an episode with no page
/// stands in its audio link for its page). A separate episode web page still goes, through `ShareableLinkPolicy`: it is
/// not an access detail. A friend still finds the episode in their own copy by GUID, show, title, date and length
/// (#177, #454). No tag, a manual add, no catalog match or a self-hosted feed is no evidence of anything, so such an
/// episode shares as before. Nothing here makes a request.
public enum AutomaticSourceAccess {
    public enum Restriction: String, Equatable, Sendable {
        case publisherBlocked = "publisher_blocked"
        case privateFeed = "private_feed"
    }

    /// Why the item's access links stay on the device, or nil when they may go.
    public static func restriction<Fields: LibraryItemFields>(of item: Fields) -> Restriction? {
        guard isWebLink(item.media?.url) else { return nil }
        if item.publisherBlocked == true { return .publisherBlocked }
        if item.fromPrivateFeed == true { return .privateFeed }
        if let feed = item.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines), isWebLink(feed),
           ShareableLinkPolicy.shareableLink(feed) == nil {
            return .privateFeed
        }
        return nil
    }

    /// `link` as it may leave the device with `item`: nil when `ShareableLinkPolicy` refuses it, or when the item is
    /// restricted and the link is the item's audio or feed link. Otherwise the link unchanged.
    public static func sendableLink<Fields: LibraryItemFields>(_ link: String?, of item: Fields) -> String? {
        guard let shareable = ShareableLinkPolicy.shareableLink(link) else { return nil }
        guard restriction(of: item) != nil else { return shareable }
        let key = comparisonKey(shareable)
        let accessLinks = [item.media?.url, item.sourceURL].compactMap { $0 }.map(comparisonKey)
        return accessLinks.contains(key) ? nil : shareable
    }

    /// The episode's GUID as it may leave the device: as `ShareableLinkPolicy` says, and for a restricted item not when
    /// the GUID is its audio or feed link (many hosts use the audio link as the GUID).
    public static func sendableEpisodeGUID<Fields: LibraryItemFields>(_ guid: String?, of item: Fields) -> String? {
        guard let shared = ShareableLinkPolicy.shareableEpisodeGUID(guid) else { return nil }
        guard isWebLink(shared) else { return shared }
        return sendableLink(shared, of: item)
    }

    /// The item's audio link as it may leave the device: nil for a restricted item, else as `ShareableLinkPolicy` says.
    public static func sendableAudioLink<Fields: LibraryItemFields>(of item: Fields) -> String? {
        restriction(of: item) == nil ? ShareableLinkPolicy.shareableLink(item.media?.url) : nil
    }

    private static func isWebLink(_ value: String?) -> Bool {
        guard let value, let scheme = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// Two spellings of one address compare equal: scheme and host in any case, http or https, the path's escapes
    /// written either way, with or without a fragment or a trailing slash.
    private static func comparisonKey(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        // One spelling of each escape: `%7E` and `~`, `%2d` and `-` name the same address.
        components.path = components.path
        while components.path.hasSuffix("/") && components.path.count > 1 { components.path.removeLast() }
        return components.string ?? trimmed
    }
}
