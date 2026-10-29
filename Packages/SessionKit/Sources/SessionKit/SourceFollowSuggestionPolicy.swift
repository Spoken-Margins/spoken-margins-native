import Foundation

/// When the "follow this source" card may appear, and the records the listener's answer saves (#994).
/// Moved out of Gate1AppModel so the 25 percent threshold lives in one place and the rules run on
/// Linux. The network discovery, the diagnostics lines and the saves stay in the model.
/// ``FollowedSourceMatching/suggestible(_:now:decision:)`` holds the separate 30-day rule for which
/// discovered feeds may be offered again; "Not now" below ends after 14 days and the two are not merged.
public enum SourceFollowSuggestionPolicy {
    /// Listening progress, in percent, at which an item counts as engaged enough to suggest its source.
    public static let engagementThresholdPercent = 25

    /// How long "Not now" holds the card back for that source.
    public static let notNowSuppressionInterval: TimeInterval = 14 * 24 * 60 * 60

    /// What the listener tapped on the card to say no.
    public enum Answer: Equatable, Sendable {
        case notNow
        case neverSuggest

        var kind: SourceSuggestionDecisionKind {
            switch self {
            case .notNow: .notNow
            case .neverSuggest: .neverSuggest
            }
        }

        /// "Never" has no end date.
        func suppressUntil(from now: Date) -> Date? {
            switch self {
            case .notNow: now.addingTimeInterval(SourceFollowSuggestionPolicy.notNowSuppressionInterval)
            case .neverSuggest: nil
            }
        }
    }

    /// Whether one playback tick moved the item across the threshold. The card is checked once, at
    /// the crossing, so a tick that stays above or below it asks nothing.
    public static func crossedEngagementThreshold(previous: Int, current: Int) -> Bool {
        previous < engagementThresholdPercent && current >= engagementThresholdPercent
    }

    /// The larger of the saved progress and the live progress of the playing item, so a card is not
    /// held back while the Library row has yet to catch up with the player.
    public static func engagementProgress(
        itemId: String,
        persistedProgress: Int?,
        snapshot: SessionSnapshot
    ) -> Int {
        let liveProgress = snapshot.itemId == itemId ? snapshot.currentPlaybackProgressPercent : 0
        return max(persistedProgress ?? 0, liveProgress)
    }

    /// Whether the listener has engaged with the item: far enough in, or a Margin of their own on it.
    public static func isEngaged(progress: Int, itemHasMargin: Bool) -> Bool {
        progress >= engagementThresholdPercent || itemHasMargin
    }

    /// Whether the item still names the same origin it did when discovery began. Discovery is
    /// slow, and a result for an origin that changed meanwhile belongs to nothing the listener sees.
    public static func hasSameOrigin(_ original: some LibraryItemFields, _ current: some LibraryItemFields) -> Bool {
        current.sourceURL == original.sourceURL
            && current.externalReference == original.externalReference
            && current.media?.url == original.media?.url
    }

    /// The records saved before the card shows, one per offered feed. Saving them first keeps the
    /// same feed from being offered again right away.
    public static func promptedDecisions(
        for candidates: [SourceCandidateEvidence], now: Date
    ) -> [SourceSuggestionDecision] {
        candidates.map {
            SourceSuggestionDecision(sourceId: $0.source.id, decision: .prompted, decidedAt: now, lastPromptAt: now)
        }
    }

    /// The records for the listener's answer on the card, one per offered feed. An earlier
    /// `lastPromptAt` is kept; a feed with none is stamped `now`. `prior` reads the saved record.
    public static func decisions(
        for answer: Answer,
        candidates: [SourceCandidateEvidence],
        now: Date,
        prior: (String) -> SourceSuggestionDecision?
    ) -> [SourceSuggestionDecision] {
        candidates.map {
            SourceSuggestionDecision(
                sourceId: $0.source.id, decision: answer.kind, decidedAt: now,
                suppressUntil: answer.suppressUntil(from: now),
                lastPromptAt: prior($0.source.id)?.lastPromptAt ?? now
            )
        }
    }
}
