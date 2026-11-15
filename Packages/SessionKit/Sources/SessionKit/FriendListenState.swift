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

    /// - Parameters:
    ///   - selectedItemId: the item the Now screen shows.
    ///   - playingItemId: the item that is playing. A friend's packet on one item while another plays gives no friend
    ///     listen for the playing one, and none for the packet's item either, since it is not on Now.
    ///   - entryCount: how many of the selected item's friend Margins are new and will play (`SharedMarginReview.entries`).
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
