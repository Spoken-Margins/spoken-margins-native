import Foundation

/// Whether the listener has put off or refused one suggestion (#4046). Stored as record kind `rule_suggestion_state`, which
/// Build 29 and later shipped builds never read. The record id is the key.
public struct RuleSuggestionState: Codable, Equatable, Sendable, Identifiable {
    /// `RuleSuggestionState.key(feedKey:word:)`.
    public let key: String
    /// "Not now": the suggestion stays quiet until this date.
    public var snoozedUntil: Date?
    /// "Don't suggest this": forever.
    public var never: Bool

    public var id: String { key }

    public init(key: String, snoozedUntil: Date? = nil, never: Bool = false) {
        self.key = key
        self.snoozedUntil = snoozedUntil
        self.never = never
    }

    /// One suggestion per show and word. The word is folded and holds only letters, so the first `|` ends it.
    public static func key(feedKey: String, word: String) -> String { "\(word)|\(feedKey)" }

    /// "Not now": snoozed for `RuleSuggester.snoozeDays` days.
    public static func snoozed(key: String, now: Date) -> RuleSuggestionState {
        RuleSuggestionState(key: key, snoozedUntil: now.addingTimeInterval(Double(RuleSuggester.snoozeDays) * 86_400))
    }

    /// "Don't suggest this".
    public static func refused(key: String) -> RuleSuggestionState { RuleSuggestionState(key: key, never: true) }

    func silences(at now: Date) -> Bool {
        never || (snoozedUntil.map { $0 > now } ?? false)
    }
}

/// A followed show as the learner reads it (#4046): who it is, its name, and the episodes the feed lists.
public struct RuleSuggestionShow: Sendable {
    public let id: String
    public let member: ListMember
    public let title: String
    public var entries: [FeedEntry]

    public init(id: String, member: ListMember, title: String, entries: [FeedEntry]) {
        self.id = id
        self.member = member
        self.title = title
        self.entries = entries
    }
}

/// Why a suggestion is offered, in the words the card shows (#4046).
public enum RuleSuggestionReason: Equatable, Sendable {
    /// The listener marked this many episodes about the word Show less.
    case marked(Int)
    /// The listener left this many episodes about the word without a Margin: finished, put down half way, or never played.
    case quiet(Int)

    public var line: String {
        switch self {
        case .marked(let count): "You marked \(count) like this Show less."
        case .quiet(let count): "You didn’t leave a Margin on \(count) like this."
        }
    }
}

/// One offered rule: skip a show's episodes about a word (#4046). The listener turns it on, puts it off or refuses it; nothing
/// acts before that.
public struct RuleSuggestion: Equatable, Sendable, Identifiable {
    public let key: String
    public let showId: String
    public let member: ListMember
    public let showTitle: String
    /// Folded: lowercase, without diacritics. A skip rule on it matches the episodes the listener meant.
    public let word: String
    /// The weight sum behind it. Stronger suggestions come first.
    public let strength: Int
    /// How many episodes with a signal carry the word.
    public let episodeCount: Int
    public let reason: RuleSuggestionReason

    public var id: String { key }
    public var reasonLine: String { reason.line }
}

/// The on-device rule learner (#4046). It reads evidence the device built (`RuleEvidenceBuilder`), searches episode titles for a
/// word the listener keeps passing over in one show, and offers a skip rule. No model and no network; the clock is an input.
///
/// A suggestion (show, word) needs all of:
/// - a weight sum of 4 or more, over 3 or more episodes whose titles a skip rule on the word would match;
/// - no positive episode (one the listener left a Margin on, or shared), of any age, whose title carries it;
/// - a match on at most half of the show's last 30 episodes, so a word the show says all the time isn't offered.
///
/// A word is a candidate when it is at least four letters, folded, not on the stopword list and not a word of the show's own
/// title. Evidence older than 90 days is not read, except that a positive episode vetoes its words whatever its age. A show
/// whose episodes aren't known gets no suggestion. The thresholds are cautious first numbers and live here.
public enum RuleSuggester {
    public static let windowDays = 90
    public static let minimumWeight = 4
    public static let minimumEpisodes = 3
    /// The most of a show's last 30 episodes a word may match.
    public static let maximumShareOfShow = 0.5
    public static let snoozeDays = 30
    public static let minimumWordLength = 4

    public static func suggest(
        evidence: [EpisodeEvidence],
        shows: [RuleSuggestionShow],
        rules: [ListeningRule],
        states: [RuleSuggestionState],
        lists: [FollowList] = [],
        now: Date
    ) -> [RuleSuggestion] {
        guard !evidence.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let silenced = Set(states.filter { $0.silences(at: now) }.map(\.key))
        let skipRules = rules.filter { $0.action == .skip }
        var suggestions: [RuleSuggestion] = []

        for show in shows {
            let ofShow = evidence.filter { show.member.matches(feedKey: $0.feedKey) }
            let episodes = ofShow.filter { $0.at >= cutoff }
            guard episodes.count >= minimumEpisodes else { continue }
            let showTitleWords = Set(ListeningRuleMatcher.Pattern.tokens(of: show.title))
            let covering = skipRules
                .filter { ListeningRuleEvaluator.covers($0.scope, show: show.member, lists: lists) }
                .map { ListeningRuleMatcher(words: $0.words) }

            var byWord: [String: [EpisodeEvidence]] = [:]
            for episode in episodes {
                for word in candidateWords(in: episode.title) where !showTitleWords.contains(word) {
                    byWord[word, default: []].append(episode)
                }
            }

            // Without the show's episodes there is no way to tell how often it says the word, so nothing is offered.
            let window = ListeningRuleEvaluator.windowIndices(show.entries).map { show.entries[$0] }
            guard !window.isEmpty else { continue }
            let windowTexts = window.map { ListeningRuleText(title: $0.title, summary: $0.summary) }
            // A Margin or a share on an episode about the word vetoes it for good, so the veto reads all the evidence, not just
            // the 90-day window.
            let vetoed = Set(ofShow.filter(\.positive).flatMap { candidateWords(in: $0.title) })
            for (word, carrying) in byWord {
                if vetoed.contains(word) { continue }
                // Only episodes the rule would itself match count, so a suggested rule always skips what the listener passed over.
                let matcher = ListeningRuleMatcher(words: [word])
                let signalled = carrying.filter { $0.weight > 0 && matcher.matches(title: $0.title) }
                let strength = signalled.reduce(0) { $0 + $1.weight }
                guard strength >= minimumWeight, signalled.count >= minimumEpisodes else { continue }
                guard case .valid = ListeningRuleWords.validate([word]) else { continue }
                let key = RuleSuggestionState.key(feedKey: show.member.feedKey, word: word)
                if silenced.contains(key) { continue }
                let wordText = ListeningRuleText(title: word, summary: nil)
                if covering.contains(where: { $0.matches(wordText) }) { continue }
                let matched = windowTexts.filter { matcher.matches($0) }.count
                guard Double(matched) <= Double(windowTexts.count) * maximumShareOfShow else { continue }
                let marked = signalled.filter(\.showLess).count
                suggestions.append(RuleSuggestion(
                    key: key, showId: show.id, member: show.member, showTitle: show.title, word: word,
                    strength: strength, episodeCount: signalled.count,
                    reason: marked > 0 ? .marked(marked) : .quiet(signalled.count)
                ))
            }
        }
        return suggestions.sorted { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            if lhs.episodeCount != rhs.episodeCount { return lhs.episodeCount > rhs.episodeCount }
            if lhs.showTitle != rhs.showTitle { return lhs.showTitle < rhs.showTitle }
            return lhs.word < rhs.word
        }
    }

    /// The words of a title the learner may offer, once each: folded, at least four letters, nothing but letters (a number or a
    /// word with an apostrophe says nothing a rule could match back: the rule `trump` does not match "Trump's"), and not a
    /// stopword.
    static func candidateWords(in title: String) -> Set<String> {
        var words = Set<String>()
        for token in ListeningRuleMatcher.Pattern.tokens(of: title) {
            let word = token
            guard word.count >= minimumWordLength, word.allSatisfy(\.isLetter), !RuleSuggesterStopwords.contains(word) else { continue }
            words.insert(word)
        }
        return words
    }
}
