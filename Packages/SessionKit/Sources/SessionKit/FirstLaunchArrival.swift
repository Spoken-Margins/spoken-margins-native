import Foundation

/// #4672 (rule 5): for someone who arrived by a friend's file or link, the gentlest ask comes at the end of the
/// episode: "Follow this show", once, and nothing more.
///
/// The arrival item is the item a friend's file or link opened on a first launch. It is remembered on the phone, not
/// derived from the first Margin, so it reaches friends who never make one. Everything is `UserDefaults` only: the
/// answer is never in a packet, an export or the database.
public struct FirstLaunchArrival {
    /// The first friend's item this install opened on its first launch.
    public static let itemIdKey = "firstLaunchArrivalItemIdV1"
    /// Set when the card has been put on screen. Showing counts as offering.
    public static let offeredKey = "arrivalFollowOfferedV1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var itemId: String? { defaults.string(forKey: Self.itemIdKey) }

    /// Remembers `id` as the arrival item unless one is already remembered: a second friend's file does not move the
    /// card to another show. Returns whether `id` was stored.
    @discardableResult
    public mutating func recordItem(_ id: String) -> Bool {
        guard !id.isEmpty, itemId == nil else { return false }
        defaults.set(id, forKey: Self.itemIdKey)
        return true
    }

    public func isArrivalItem(_ id: String) -> Bool {
        guard let itemId, !id.isEmpty else { return false }
        return itemId == id
    }

    public var hasOffered: Bool { defaults.bool(forKey: Self.offeredKey) }

    public mutating func markOffered() {
        defaults.set(true, forKey: Self.offeredKey)
    }

    /// Whether the card shows now. Every input must hold. Not showing (no feed found, offline) is not offering, so
    /// nothing is marked and a later finish with a network still gets the card.
    public static func shouldOfferFollow(
        isArrivalItem: Bool,
        finished: Bool,
        canFollow: Bool,
        decisionExists: Bool,
        alreadyOffered: Bool
    ) -> Bool {
        isArrivalItem && finished && canFollow && !decisionExists && !alreadyOffered
    }

    /// Whether a stored decision for the show is a real answer that keeps the card away: followed, never, or a
    /// "Not now" whose hold is still in force. A `.prompted` record only says the suggestion card was about to show.
    public static func answerSuppressesOffer(_ decision: SourceSuggestionDecision?, now: Date) -> Bool {
        guard let decision else { return false }
        switch decision.decision {
        case .prompted: return false
        case .accepted, .neverSuggest: return true
        case .notNow:
            guard let until = decision.suppressUntil else { return true }
            return until > now
        }
    }

    /// The one show a single tap on the card follows. Nil when discovery found nothing, when it found several feeds
    /// (the Follow button opens a chooser for those) or one the listener must confirm: a card with one button can't ask.
    public static func followTarget(from offer: FollowOffer?) -> SourceCandidateEvidence? {
        guard let offer, offer.candidates.count == 1, let candidate = offer.candidates.first,
              !candidate.needsConfirmation else { return nil }
        return candidate
    }

    /// "Not now": the same 14-day hold the suggestion card's Not now writes, for the show the card named.
    public static func notNowDecision(
        for candidate: SourceCandidateEvidence,
        now: Date,
        prior: (String) -> SourceSuggestionDecision?
    ) -> SourceSuggestionDecision {
        SourceFollowSuggestionPolicy.decisions(for: .notNow, candidates: [candidate], now: now, prior: prior)[0]
    }
}
