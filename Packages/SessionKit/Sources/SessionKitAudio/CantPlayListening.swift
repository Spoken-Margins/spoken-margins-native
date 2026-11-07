import Foundation
import SessionKit

/// When a friend's episode can't play (a private feed, a removed episode), the app's voice reads the words before each
/// Margin and then the sender's Margin plays (owner, 2026-11-02, #3392, `docs/decisions.md`): the Margin's quote, the
/// source words just before the moment, or, for a Margin with no quote, its place: the time and the episode's title.
///
/// This type holds what is decidable on the host: whether to take this path, the order (each Margin: its words, then
/// the Margin), and the words. It plays nothing. The app hands the steps to the one Margin-moment machine
/// (`MarginMomentSequence`), so heard-marking, the chime, skip and interruptions are the ones every friend Margin has.
///
/// The words the voice reads are the episode's, not the sender's. They are introduced as the episode's, and the sender's
/// own Margin follows with the shared-Margin chime (or, for a written one, "Cole wrote:"), so a synthetic voice never
/// passes for the sender's own (owner, 2026-11-02, #3247).
public enum CantPlayListening {
    /// How the voice introduces a quote (owner's wording, 2026-11-06, #3392).
    public static let quoteIntro = "The episode says:"
    /// A quote longer than this is cut at a word, so the words before a Margin never run for minutes.
    public static let longestQuoteCharacters = 240

    // MARK: Whether to take this path

    /// The part of a player snapshot that says how an attempt to start went.
    public struct Start: Equatable, Sendable {
        public let itemId: String?
        public let status: PlaybackStatus
        public let lastFailure: String?

        public init(itemId: String?, status: PlaybackStatus, lastFailure: String?) {
            self.itemId = itemId
            self.status = status
            self.lastFailure = lastFailure
        }
    }

    /// The player's last start failed for good and none has confirmed since. It reads the failure the engine keeps until
    /// a start confirms, because the status alone doesn't last: anything that pauses a failed player (an ordinary review
    /// giving its place back, a recording) makes it `.paused`, and the episode is no less dead (PR #3606's audit). A new
    /// attempt is `.starting`, so Review keeps its retry while the player tries.
    public static func isStartFailure(_ start: Start) -> Bool {
        (start.status == .failed || start.status == .paused) && start.lastFailure?.hasPrefix("playback_start_failed:") == true
    }

    /// What the app knows about the item and the moment, beside the player's own change.
    public struct Surroundings: Equatable, Sendable {
        public let selectedItemId: String
        public let isPodcastEpisode: Bool
        /// A downloaded or brought file is on the phone.
        public let hasPlayableFile: Bool
        public let friendMargins: Int
        public let appIsActive: Bool
        /// The listener is on the playback screen at this moment.
        public let onPlaybackScreen: Bool

        public init(
            selectedItemId: String, isPodcastEpisode: Bool, hasPlayableFile: Bool, friendMargins: Int,
            appIsActive: Bool, onPlaybackScreen: Bool
        ) {
            self.selectedItemId = selectedItemId
            self.isPodcastEpisode = isPodcastEpisode
            self.hasPlayableFile = hasPlayableFile
            self.friendMargins = friendMargins
            self.appIsActive = appIsActive
            self.onPlaybackScreen = onPlaybackScreen
        }
    }

    /// The episode is dead: its start failed, for the open podcast episode, and no file is on the phone to play instead.
    /// A file on the phone (downloaded or brought) that won't start keeps its own message ("Download Again").
    public static func isDeadEpisode(_ now: Start, _ around: Surroundings) -> Bool {
        isStartFailure(now) && around.isPodcastEpisode && !around.hasPlayableFile && now.itemId == around.selectedItemId
    }

    /// The one trigger for a listening nobody asked for: this attempt to start this episode just failed. It is the
    /// change from `.starting` to `.failed` with a start failure, so it can't fire on an old failure (a snapshot that
    /// was already failed is not a change), a mid-playback failure or an article. While the player is still recovering
    /// the status stays `.starting`, so Review keeps its retry. Nobody is made to listen: it needs the app active and
    /// the listener already on the playback screen at that moment, so a Lock Screen or CarPlay Play on a dead episode
    /// gets the ordinary failure.
    public static func startFailed(from old: Start, to new: Start, around: Surroundings) -> Bool {
        guard around.friendMargins > 0, around.appIsActive, around.onPlaybackScreen else { return false }
        guard old.status == .starting, new.status == .failed, old.itemId == new.itemId else { return false }
        return isDeadEpisode(new, around)
    }

    // MARK: Whether the world still wants it

    /// The few facts about the app that decide whether a listening that waited a moment should still start.
    public struct Scene: Equatable, Sendable {
        public let playerItemId: String?
        public let selectedItemId: String
        public let status: PlaybackStatus
        public let isRecording: Bool
        /// Which screen is showing (any stable name): leaving it, for another screen or Home, drops the listening.
        public let screen: String
        public let hasMarginMoment: Bool

        public init(
            playerItemId: String?, selectedItemId: String, status: PlaybackStatus, isRecording: Bool,
            screen: String, hasMarginMoment: Bool
        ) {
            self.playerItemId = playerItemId
            self.selectedItemId = selectedItemId
            self.status = status
            self.isRecording = isRecording
            self.screen = screen
            self.hasMarginMoment = hasMarginMoment
        }
    }

    /// Whether the listening decided in `began` still starts in `now`, after the words had time to render. It doesn't if
    /// the listener moved on: another item, a recording, a pause or Play (any change of status except a stalled start
    /// that then reported its failure), leaving the playback screen, or another Margin moment that started meanwhile.
    /// Nothing is ended or paused before this says yes, so a listening that is dropped leaves the app as it was.
    public static func stillWanted(itemId: String, began: Scene, now: Scene) -> Bool {
        guard now.playerItemId == itemId, now.selectedItemId == itemId, !now.isRecording else { return false }
        guard now.screen == began.screen else { return false }
        guard began.hasMarginMoment || !now.hasMarginMoment else { return false }
        return now.status == began.status
    }

    // MARK: The sequence

    public enum Context: Equatable, Sendable {
        /// The Margin's quote, as the voice is given it (links and emoji removed, cut at a word).
        case quote(String)
        /// No quote the voice can read: the time and the episode.
        case place(timeWords: String, title: String)
    }

    /// One Margin with what is read before it.
    public struct Beat: Equatable, Sendable {
        public let entry: SharedMarginReview.Entry
        public let context: Context
        public var marginId: String { entry.marginId }
        /// The id the words play under in the Margin-moment machine. Never a Margin's own id, so it is never marked heard.
        public var contextId: String { CantPlayListening.contextId(for: marginId) }
        /// What the voice says first. Introduced and read by the same reader a written Margin uses.
        public var reading: WrittenMarginReading {
            let itemId = entry.layer.itemId ?? ""
            switch context {
            case .quote(let words): return WrittenMarginReading(intro: CantPlayListening.quoteIntro, text: words, itemId: itemId)
            case .place(let timeWords, let title):
                return WrittenMarginReading(intro: "\(timeWords), in", text: title, itemId: itemId)
            }
        }
        public var spokenContext: String { reading.spokenText }
    }

    public static func contextId(for marginId: String) -> String { "cant-play::\(marginId)" }
    public static func isContextId(_ id: String) -> Bool { id.hasPrefix("cant-play::") }

    /// The Margins in playing order, each with the words read before it. A Margin with nothing to play (no recording, no
    /// words the voice will read) is left out together with its words, so nothing introduces silence. The order of
    /// `entries` is kept: `SharedMarginReview.entries` already sorts by place, then sender, then time.
    ///
    /// `voiceFor` and `defaultVoice` are the installed voices (as `WrittenMarginVoice.voice` takes them). A quote in a
    /// language no installed voice reads becomes its place, the same as a quote the voice can't say at all.
    public static func plan(
        entries: [SharedMarginReview.Entry],
        episodeTitle: String?,
        voiceFor: (String) -> String? = { $0 },
        defaultVoice: () -> String? = { "default" }
    ) -> [Beat] {
        entries.compactMap { entry in
            guard SharedMarginAudio.canOffer(entry.interjection) else { return nil }
            let context: Context
            if let quote = readableQuote(of: entry.interjection.anchorEvidence, voiceFor: voiceFor, defaultVoice: defaultVoice) {
                context = .quote(quote)
            } else {
                context = .place(timeWords: timeWords(forMediaTimeMs: entry.mediaTimeMs), title: title(episodeTitle))
            }
            return Beat(entry: entry, context: context)
        }
    }

    /// The anchors the Margin-moment machine plays, in order: each Margin's words, then the Margin. All sit at one place
    /// (`placeMs`, where the episode already stands), because there is no episode to move through: the machine plays the
    /// next one at once and never seeks. The time the Margin belongs to is in the words, not in the anchor.
    public static func anchors(for beats: [Beat], placeMs: Int) -> [MarginMomentAnchor] {
        beats.flatMap { beat -> [MarginMomentAnchor] in
            let margin = MarginMomentAnchor(
                marginId: beat.marginId, mediaTimeMs: placeMs, label: beat.entry.senderLabel,
                isApproximate: beat.entry.isApproximate, caption: beat.entry.replyContext?.caption,
                isReadAloud: beat.entry.interjection.isWritten
            )
            // The words carry the Margin's sender so the card can name whose Margin is coming; the card never says the
            // sender wrote them (`isReadAloud` stays false and the card shows its "getting ready" stage, see `isWordsStep`).
            let words = MarginMomentAnchor(marginId: beat.contextId, mediaTimeMs: placeMs, label: beat.entry.senderLabel, isApproximate: false)
            return [words, margin]
        }
    }

    /// A can't-play listening is the one review with no lead-in: there is no episode to lead in with. The machine's own
    /// `Review.leadInMs` marks it, so no second flag or state is kept.
    public static let leadInMs = 0

    public static func sequence(for beats: [Beat], itemId: String, placeMs: Int) -> MarginMomentSequence? {
        MarginMomentSequence(
            itemId: itemId, reviewing: anchors(for: beats, placeMs: placeMs), returnToMediaTimeMs: nil, resumesAtEnd: false,
            leadInMs: leadInMs
        )
    }

    public static func isCantPlayListening(_ sequence: MarginMomentSequence) -> Bool { sequence.review?.leadInMs == leadInMs }

    /// The words (not the Margin) are what has the floor or is next.
    public static func isWordsStep(_ sequence: MarginMomentSequence) -> Bool {
        isCantPlayListening(sequence) && isContextId((sequence.playing ?? sequence.target).marginId)
    }

    /// The Margins (never their words) a listening that stopped early didn't reach. The ordinary review counts a Margin
    /// as unreached only when it lies ahead of the place the listener left off; here every Margin sits at one flat
    /// place, so all of the unplayed ones count and go back to the automatic prompts.
    public static func unreachedMarginIds(in sequence: MarginMomentSequence) -> Set<String> {
        var left = sequence.unplayed
        if let playing = sequence.playing { left.append(playing) }
        return Set(left.map(\.marginId).filter { !isContextId($0) })
    }

    /// "2 of 3" counting Margins, not their words. Nil outside a can't-play listening.
    public static func position(in sequence: MarginMomentSequence) -> String? {
        guard isCantPlayListening(sequence), let review = sequence.review, let number = sequence.reviewNumber else { return nil }
        return "\((number + 1) / 2) of \(review.count / 2)"
    }

    // MARK: The words

    /// The quote a voice can read, or nil. A packet's quote is `exactText` (an article) or, for audio, the words just
    /// before the moment (`prefix`), which is what a podcast Margin carries.
    static func readableQuote(
        of evidence: PortableAnchorEvidence, voiceFor: (String) -> String?, defaultVoice: () -> String?
    ) -> String? {
        for (candidate, takingEnd) in [(evidence.exactText, false), (evidence.prefix, true)] {
            guard let candidate, WrittenMarginSpeech.isReadable(candidate) else { continue }
            let words = cut(WrittenMarginSpeech.speakable(candidate), takingEnd: takingEnd)
            guard WrittenMarginVoice.voice(forNote: words, voiceFor: voiceFor, defaultVoice: defaultVoice) != nil else { continue }
            return words
        }
        return nil
    }

    /// At most `longestQuoteCharacters`, on a word boundary. Words before a moment keep their end (the words nearest the
    /// Margin); an article's quote keeps its start.
    static func cut(_ words: String, takingEnd: Bool) -> String {
        guard words.count > longestQuoteCharacters else { return words }
        let parts = words.split(separator: " ")
        var kept: [Substring] = []
        var length = 0
        for part in (takingEnd ? parts.reversed() : parts) {
            if length + part.count + 1 > longestQuoteCharacters, !kept.isEmpty { break }
            kept.append(part)
            length += part.count + 1
        }
        let joined = (takingEnd ? kept.reversed() : kept).joined(separator: " ")
        // Text with no spaces (Japanese, Chinese) has no word to cut at: cut at the character limit.
        guard joined.count > longestQuoteCharacters else { return joined }
        return String(takingEnd ? joined.suffix(longestQuoteCharacters) : joined.prefix(longestQuoteCharacters))
    }

    /// "At 40 seconds", "At 12 minutes", "At 1 hour 5 minutes". Whole minutes, never rounded up, so the voice never
    /// names a time the Margin hasn't reached.
    public static func timeWords(forMediaTimeMs ms: Int) -> String {
        let seconds = max(0, ms) / 1_000
        if seconds == 0 { return "At the start" }
        if seconds < 60 { return "At \(seconds) \(seconds == 1 ? "second" : "seconds")" }
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if hours == 0 { return "At \(unit(minutes, "minute"))" }
        return minutes == 0 ? "At \(unit(hours, "hour"))" : "At \(unit(hours, "hour")) \(unit(minutes, "minute"))"
    }

    /// The episode's title as the voice says it, or "this episode" when it has none.
    static func title(_ title: String?) -> String {
        let spoken = WrittenMarginSpeech.speakable(title ?? "")
        return WrittenMarginSpeech.isReadable(spoken) ? cut(spoken, takingEnd: false) : "this episode"
    }
}
