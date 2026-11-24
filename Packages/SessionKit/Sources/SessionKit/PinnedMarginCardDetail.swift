import Foundation

/// The one line under the pinned card's headline while it counts down to a friend's Margin, or plays one (#4175).
/// `PinnedMarginCardView.detail(_:)` hands in what the model knows, so the order of the lines can be tested on the host.
///
/// Two ways to reach a friend's Margin put up a countdown card:
/// - a Margin moment (a review from "Skip to <friend>'s Margins", or a Margin played from its row), stage `comingUp`;
/// - ordinary playback with auto-play on (Play, or "Skip to just before <friend>"), stage `upNext(_, .playsByItself)`.
///
/// Before #4175's Test Desk run only the first read the Margin's placement, so on the second the copy-length note and
/// the "Approximate position" caution never showed, and J5 step 2 always read "Plays by itself when you get there.".
public enum PinnedMarginCardDetail {
    /// What the card knows about the Margin it is about.
    public struct Target: Equatable, Sendable {
        public let isPodcast: Bool
        /// On a podcast: the countdown line from `SharedMarginPlacementWording.pinnedCardLine`, nil unless placed roughly.
        public let placementLine: String?
        /// On any other source: where its placement pass has got to, nil once it is placed.
        public let placingDescription: String?

        public init(isPodcast: Bool, placementLine: String?, placingDescription: String?) {
            self.isPodcast = isPodcast
            self.placementLine = placementLine
            self.placingDescription = placingDescription
        }

        /// From a friend's Margin and its layer. `plan` is where it plays in this copy; `listenerCopyMs` is the length
        /// of the copy playing now (nil when the player has not reported one, or another item is playing).
        public init(
            interjection: ImportedCommentaryInterjection, layer: ImportedCommentaryLayer, plan: SharedMarginPlacementPlan,
            placingDescription: String?, listenerCopyMs: Int?, subject: PinnedMarginCard.Subject
        ) {
            let isPodcast = layer.itemIdentity.itemType == .podcast
            self.isPodcast = isPodcast
            self.placementLine = isPodcast
                ? SharedMarginPlacementWording.pinnedCardLine(
                    for: plan,
                    // A Margin shifted by its matched neighbours has the ad difference taken out already.
                    atSenderClock: interjection.resolution.evidenceClass != .mapInterpolated,
                    senderCopyMs: layer.itemIdentity.durationMs, listenerCopyMs: listenerCopyMs, subject: subject)
                : nil
            self.placingDescription = isPodcast ? nil : placingDescription
        }
    }

    /// A Margin moment's state, when one holds the card.
    public struct Moment: Equatable, Sendable {
        public let isPlayingMargin: Bool
        public let caption: String?
        /// The Margin's place, or the moment's own position, is a guess.
        public let isApproximate: Bool

        public init(isPlayingMargin: Bool, caption: String?, isApproximate: Bool) {
            self.isPlayingMargin = isPlayingMargin
            self.caption = caption
            self.isApproximate = isApproximate
        }
    }

    /// The line: what is wrong with the Margin's place first (being placed, an approximate place), then what a reply
    /// answers, then what the stage means. A card no Margin moment holds keeps its own line except while it counts down
    /// to a podcast Margin that plays by itself: the line it would replace says nothing the countdown doesn't, while a
    /// tone or "won't play by itself" tells the listener what to do and stays.
    public static func line(for card: PinnedMarginCard, moment: Moment?, target: Target?) -> String {
        guard let moment else {
            if case .upNext(_, .playsByItself) = card.stage, case .friend = card.subject,
               let target, target.isPodcast, let note = target.placementLine {
                return note
            }
            return card.detail
        }
        if let target {
            if target.isPodcast {
                if let note = target.placementLine, moment.caption == nil, !moment.isPlayingMargin { return note }
            } else if let placing = target.placingDescription {
                return placing
            }
        }
        if let caption = moment.caption { return caption }
        if !moment.isPlayingMargin, moment.isApproximate { return SharedMarginPlacementWording.approximatePositionNote }
        return card.detail
    }
}
