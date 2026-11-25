import Foundation

/// The words that go out beside a share link (#3787). A bare address reads as spam to a friend who has never heard of
/// the app, so the share sheet carries one sentence with it. The sentence is the owner's pick of 2026-11-09.
///
/// The sentence and the address travel as one text, not as a text item beside a URL item: Messages and Mail show both
/// of two items, but other apps keep one and drop the other, and a friend who gets only the address is back where
/// this started. The sender can edit the text in whatever app takes it, as with any shared text. The link's own
/// preview stays sealed and generic (#486); nothing here touches it.
///
/// The sentence is true for what was shared (#5264): it names the kind of item and what is going, and it promises
/// "works in your browser, nothing to install" only when the browser can play the link, or for an episode with an
/// audio address or page whose background check (#4454) hasn't finished. Choosing it never waits on that check.
public enum ShareLinkMessage {
    /// The owner's sentence: one voice note on an episode the browser can play.
    public static let sentence = "I left you a voice note on a podcast. Tap the link, then Play. It works in your browser, nothing to install."

    /// What was shared, from the packet's item type and whether the shared item is a Spoken Note.
    public enum SharedKind: String, CaseIterable, Equatable, Sendable {
        case episode, article, pdf, book, spokenNote, recording

        public init(itemType: SharedItemType, isSpokenNote: Bool) {
            switch itemType {
            case .podcast: self = .episode
            case .text: self = isSpokenNote ? .spokenNote : .article
            case .pdf: self = .pdf
            case .epub: self = .book
            case .other: self = .recording
            }
        }

        /// "I left you … on {on}."
        var on: String {
            switch self {
            case .episode: "a podcast"
            case .article: "an article"
            case .pdf: "a PDF"
            case .book: "a book"
            case .spokenNote: "something I wrote"
            case .recording: "a recording"
            }
        }

        /// "… to hear it with {with}."
        var with: String {
            switch self {
            case .episode: "the episode"
            case .article: "the article"
            case .pdf: "the PDF"
            case .book: "the book"
            case .spokenNote: "what I wrote"
            case .recording: "the recording"
            }
        }
    }

    /// The Margins going: how many, and whether every one carries the sender's own recorded voice.
    public struct Notes: Equatable, Sendable {
        public var count: Int
        /// True only when `count > 0` and every Margin is the sender's voice (original or cleaned audio). Summary audio
        /// and the phone's voice count as words only.
        public var allVoice: Bool

        public init(count: Int, allVoice: Bool) {
            self.count = count
            self.allVoice = count > 0 && allVoice
        }

        /// Whether a representation kind is the sender's own voice. Nil (no representation) is words only.
        public static func isSendersVoice(_ kind: SharedInterjectionRepresentationKind?) -> Bool {
            switch kind {
            case .originalAudioAndText, .cleanedAudioAndText: true
            default: false
            }
        }

        public init(kinds: [SharedInterjectionRepresentationKind?]) {
            self.init(count: kinds.count, allVoice: kinds.allSatisfy(Self.isSendersVoice))
        }

        var isPlural: Bool { count >= 2 }
        var noun: String {
            switch (isPlural, allVoice) {
            case (false, true): "a voice note"
            case (true, true): "voice notes"
            case (false, false): "a note"
            case (true, false): "notes"
            }
        }
        var pronoun: String { isPlural ? "them" : "it" }
        var whatOn: String { isPlural ? "they're" : "it's" }
    }

    /// What the packet says about the share, read once beside the link's preview (`ShareLinkPacketPreview.read`).
    public struct Facts: Equatable, Sendable {
        public var itemType: SharedItemType
        public var notes: Notes
        /// The packet carries an audio address, or the link's preview carries a public page.
        public var hasAudioOrPage: Bool

        public init(itemType: SharedItemType, notes: Notes, hasAudioOrPage: Bool) {
            self.itemType = itemType
            self.notes = notes
            self.hasAudioOrPage = hasAudioOrPage
        }
    }

    /// What the background check knows about the friend's browser, in three answers.
    public enum Playability: Equatable, Sendable {
        case plays, cannot, unknown

        public init(_ outcome: ShareLinkPlayCheck.Outcome?) {
            switch outcome {
            case .plays:
                self = .plays
            case .problem(let reason):
                switch reason {
                case .article, .noEpisodeAudio, .paidPost, .noPostVoice, .audioFormat:
                    self = .cannot
                // A refusal of the phone's small read may pass later, and a link that didn't open says nothing
                // about whether its audio plays.
                case .audioRefused, .linkBroken, .linksOff:
                    self = .unknown
                }
            case .checking, .notChecked, .gone, nil:
                self = .unknown
            }
        }

        /// The newest link's own answer when it has one, otherwise the answer carried from the screen's previous link
        /// (only plays or cannot is ever carried), otherwise unknown.
        public static func current(newest: ShareLinkPlayCheck.Outcome?, carried: Playability?) -> Playability {
            let own = Playability(newest)
            if own != .unknown { return own }
            if let carried, carried != .unknown { return carried }
            return .unknown
        }
    }

    /// The sentence for one share. It can't fail and reads nothing but its arguments.
    public static func chooseSentence(item: SharedKind, notes: Notes, hasAudioOrPage: Bool, playability: Playability) -> String {
        let plays: Bool
        switch playability {
        case .plays: plays = true
        case .cannot: plays = false
        case .unknown: plays = item == .episode && hasAudioOrPage
        }
        let opening = "I left you \(notes.noun) on \(item.on)."
        if plays {
            return "\(opening) Tap the link, then Play. It works in your browser, nothing to install."
        }
        return "\(opening) You'll need Spoken Margins on iPhone to hear \(notes.pronoun) with \(item.with). The link shows what \(notes.whatOn) on and how to get the app."
    }

    /// The sentence, a blank line, then the whole address (its `#` key included).
    public static func text(for link: URL, item: SharedKind, notes: Notes, hasAudioOrPage: Bool, playability: Playability) -> String {
        let sentence = chooseSentence(item: item, notes: notes, hasAudioOrPage: hasAudioOrPage, playability: playability)
        return "\(sentence)\n\n\(link.absoluteString)"
    }
}
