import Foundation

/// Whether a friend listen is under way on the Now screen (#3790), and whether its end card is up.
///
/// While a friend's Margins play, the Now screen carries only what the friend's Margin needs at that moment: the
/// pinned card, the title, the play-mode switch. The first-Margin prompt and the transcript line of the listener's own
/// Margins wait. This is the one place that says when that is, so the screen and the onboarding rule read the same fact.
///
/// A friend listen is under way on the item on screen while that item is the one playing and either of two things
/// holds: friend Margins that will play are still ahead (`SharedMarginReview.entries`, which leaves out a wrong-source
/// layer), or the pinned card is a friend's (the countdown, the voice, the wait between Margins, or the end card). The
/// listener's own review or moment, and the card that offers Share after their reply, are not a friend listen on their
/// own account: with no friend Margin ahead they give none, and with one ahead the Margins ahead still hold it open.
public struct FriendListenState: Equatable, Sendable {
    /// A friend's Margins are playing, or about to, on the item on screen.
    public let isInProgress: Bool
    /// The card says "That was Cole's last Margin": nothing more of the friend's is ahead.
    public let isShowingEndCard: Bool

    /// No friend listen: nothing is hidden and nothing is marked.
    public static let none = FriendListenState(isInProgress: false, isShowingEndCard: false)

    private init(isInProgress: Bool, isShowingEndCard: Bool) {
        self.isInProgress = isInProgress
        self.isShowingEndCard = isShowingEndCard
    }

    /// How many of the item's new friend Margins are still ahead of the playhead, the number `entryCount` takes. A Margin
    /// the listener has gone past without hearing (a start that skipped it, a seek, a tone not tapped) stays new, but
    /// nothing will play it, so it must not hold the listen open: the prompt and the listener's own transcript line would
    /// stay hidden, with no friend card on screen to explain why (audit of #4390).
    ///
    /// Media compares by time, by `FriendMarginsPlan`'s rule (a Margin that plays after the others is ahead until the
    /// place is the end itself). Text compares by character, as the pinned card's "next Margin" does.
    /// - Parameters:
    ///   - mediaTimeMs: the playhead, for a media item; nil for text read aloud.
    ///   - textStart: the character being read, for text; nil before the first is read.
    ///   - isAtEnd: the playhead is the end of the episode.
    public static func aheadCount(
        _ entries: [SharedMarginReview.Entry], mediaTimeMs: Int?, textStart: Int?, isAtEnd: Bool
    ) -> Int {
        if let mediaTimeMs {
            return entries.count - FriendMarginsPlan.behind(entries, place: .known(mediaTimeMs: mediaTimeMs, isAtEnd: isAtEnd)).count
        }
        let from = textStart ?? -1
        return entries.filter { ($0.interjection.resolution.localStartChar ?? -1) > from }.count
    }

    /// - Parameters:
    ///   - selectedItemId: the item the Now screen shows.
    ///   - playingItemId: the item that is playing. A friend's packet on one item while another plays gives no friend
    ///     listen for the playing one, and none for the packet's item either, since it is not on Now.
    ///   - entryCount: how many of the selected item's friend Margins are new and still ahead (`aheadCount`).
    ///   - pinnedCard: the card in the pinned slot, if any.
    public init(selectedItemId: String, playingItemId: String?, entryCount: Int, pinnedCard: PinnedMarginCard?) {
        guard selectedItemId == playingItemId else {
            self = .none
            return
        }
        var cardIsFriends = false
        var endCard = false
        if let pinnedCard, case .friend = pinnedCard.subject {
            cardIsFriends = true
            if case .lastMargin = pinnedCard.stage { endCard = true }
        }
        isInProgress = entryCount > 0 || cardIsFriends
        isShowingEndCard = endCard
    }
}

extension OnboardingProgress {
    /// The end card asks the listener for a Margin of their own, so it does the first-Margin prompt's job (#3790): once it
    /// shows, the prompt counts as seen and does not come back under it or later. Anything else leaves the steps as they are.
    @discardableResult
    public mutating func noteFriendListen(_ state: FriendListenState) -> Change {
        state.isShowingEndCard ? firstMarginPromptSeen() : []
    }
}
