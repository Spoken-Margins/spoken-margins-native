import Foundation
import SessionKit

/// Whether an item the listener opened or started should have its post page read for a voiceover (#2789), and when
/// not, why. Opening the Item screen and pressing Play share it, so Library Play, Continue, the play queue and a
/// Following entry behave alike. A page is read only here and in the listener-started Following import, never in the
/// background (the owner's 2026-10-21 call, #2368).
public enum VoiceoverLookupDecision: Equatable, Sendable {
    /// What started the question. The article feed route (#4640) runs only on the listener's open or play, never at
    /// import and never when the play queue moves on by itself (no listener action, possibly locked).
    public enum Trigger: Sendable {
        case open, play, importing, queueAdvance

        var isListenerAction: Bool { self == .open || self == .play }
    }

    /// Which lookup finds the recording.
    public enum Route: Equatable, Sendable {
        /// Type III Audio's narration of a LessWrong or EA Forum post (#3438).
        case typeIII
        /// A Substack post's voiceover, on Substack or on a `/p/<slug>` address (#810).
        case substack
        /// The article's own public feed lists it with an audio enclosure (#4640).
        case articleFeed
        /// A `/p/<slug>` page on a site that isn't Substack: read as a Substack post first, and when the page has no
        /// Substack data, the article's own feed gets a chance (Default 10 of the #4640 Design). Open or play only.
        case postPageThenArticleFeed

        /// Whether the lookup may end on the article's own feed.
        public var mayUseArticleFeed: Bool { self == .articleFeed || self == .postPageThenArticleFeed }
    }

    case lookUp(address: String, route: Route)
    /// `reason` is a short token for Diagnostics: no address, title or text.
    case skip(reason: String)

    /// The provider lookup an address has, or nil. Type III and Substack addresses keep their own adapters.
    public static func providerRoute(for url: URL) -> Route? {
        if TypeIIIAudioNarration.postURL(for: url) != nil { return .typeIII }
        if PublisherNarrationEvidence.mayHaveVoiceover(url) { return .substack }
        return nil
    }

    /// Whether the article feed route may run for this address: the listener's open or play of a text article on
    /// https, from a site they don't follow (its feed already imported its audio).
    public static func allowsArticleFeed(url: URL, address: String, trigger: Trigger, mediaType: String,
                                         externalReferenceType: String?, itemId: String, siteIsFollowed: Bool) -> Bool {
        trigger.isListenerAction && mediaType.lowercased() == "text" && !siteIsFollowed
            && url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
            && ManualFollowPolicy.shouldDiscoverFeed(itemId: itemId, mediaType: mediaType, sourceURL: address,
                                                     sourceReference: address, sourceReferenceType: externalReferenceType)
    }

    public static func decide(
        textCharacterCount: Int?,
        externalReference: String?,
        hasPublisherAudioRecord: Bool,
        alreadyLookedUp: Bool,
        trigger: Trigger = .importing,
        mediaType: String = "text",
        externalReferenceType: String? = nil,
        itemId: String = "",
        siteIsFollowed: Bool = false
    ) -> VoiceoverLookupDecision {
        if alreadyLookedUp { return .skip(reason: "already_looked_up") }
        if (textCharacterCount ?? 0) <= 0 { return .skip(reason: "no_text") }
        guard let address = externalReference, let url = URL(string: address) else { return .skip(reason: "no_address") }
        let feedAllowed = allowsArticleFeed(url: url, address: address, trigger: trigger, mediaType: mediaType,
                                            externalReferenceType: externalReferenceType, itemId: itemId, siteIsFollowed: siteIsFollowed)
        let route: Route
        if let provider = providerRoute(for: url) {
            let host = (url.host ?? "").lowercased()
            let onSubstack = host == "substack.com" || host.hasSuffix(".substack.com")
            route = provider == .substack && feedAllowed && !onSubstack ? .postPageThenArticleFeed : provider
        } else if feedAllowed {
            // Any other https article, on the listener's open or play only: its own feed may carry its audio.
            route = .articleFeed
        } else {
            return .skip(reason: "not_substack_address")
        }
        if hasPublisherAudioRecord { return .skip(reason: "has_record") }
        return .lookUp(address: address, route: route)
    }
}
