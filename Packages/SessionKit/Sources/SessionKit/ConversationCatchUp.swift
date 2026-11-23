import Foundation

/// A conversation the listener is already in has a new turn waiting on an item they finished (#4785).
///
/// After a few rounds of replies, the big button on a finished episode was "Play", a replay from 0 with the reply
/// somewhere in the middle, and "Skip to Cole's replies" played the episode on after the last one. Answering a third
/// time felt like giving the friend homework. In catch-up the big button plays only the new Margins, each reply after
/// the listener's own Margin it answers, and the run pauses when the last one ends (`CatchUpRun`).
///
/// An item is in catch-up when it counts as finished (`ItemFinishedRule.isFinished`, which the Library row's
/// `isCompleted` already is) and at least one new friend Margin is a reply whose **direct** parent is the listener's
/// own Margin (`WaitingMargin.isReplyToYou`). That is a fact about the conversation, so no round is counted. A reply to
/// a friend's Margin, or one whose parent isn't on this phone, never turns it on: first packets, mid-episode arrivals
/// and J14's first-reply rows keep today's words.
public struct ConversationCatchUp: Equatable, Sendable {
    /// The new Margins the run plays, in the order given.
    public let margins: [ItemListeningChoices.WaitingMargin]

    /// The value for an item, or nil when it is not in catch-up.
    public static func make(isFinished: Bool, waiting: [ItemListeningChoices.WaitingMargin]) -> ConversationCatchUp? {
        guard isFinished, waiting.contains(where: \.isReplyToYou) else { return nil }
        return ConversationCatchUp(margins: waiting)
    }

    /// The same for the Library row, from the review entries the model already holds. An entry knows its parent is
    /// the listener's only through `replyContext.yoursParentId`; a `.shared` or `.missing` parent is never catch-up.
    public static func make(isFinished: Bool, entries: [SharedMarginReview.Entry]) -> ConversationCatchUp? {
        make(isFinished: isFinished, waiting: entries.map(\.waitingMargin))
    }

    private var mix: FriendReplyMix { FriendReplyMix(margins) }

    /// Every new Margin answers one of the listener's own.
    public var allReplies: Bool { mix.isAllReplies }
    /// How many of the new Margins are replies to the listener.
    public var replyCount: Int { mix.replies }
    /// The one sender's usable name, nil for several senders or none named (`FriendMarginsIntro.singleName`).
    public var senderName: String? { FriendMarginsIntro.singleName(margins) }

    /// "Cole's replies", "Cole's new Margins", "the replies", "the new Margins".
    var whose: String {
        let noun = allReplies ? "replies" : "new Margins"
        return senderName.map { "\($0)'s \(noun)" } ?? "the \(noun)"
    }

    /// The item screen's big button: "Hear Cole's replies · 2 min".
    public func bigButtonTitle(minutes: Int) -> String { "Hear \(whose) · \(minutes) min" }

    /// What VoiceOver reads for the big button: whose, how many and how long, and that it stops after them.
    public func bigButtonAccessibilityLabel(minutes: Int) -> String {
        "Hear \(whose), \(mix.spokenCount), about \(minutes) minute\(minutes == 1 ? "" : "s"). Pauses after the last one."
    }

    /// The Library row's question: "New replies to hear", or "New Margins to hear" when mixed.
    public var offerTitle: String { allReplies ? "New replies to hear" : "New Margins to hear" }
    /// The question's first button: the big button's words without the minutes.
    public var offerFirstButton: String { "Hear \(whose)" }

    /// How long the run takes, in whole minutes and never under one: `ItemListeningChoices.marginsOnlyMinutes` plus each
    /// distinct own parent Margin the run plays first (a spoken one whose file is present, counted once even when two
    /// replies answer it). The caller passes those lengths; a written parent or a missing file is left out, as the run
    /// leaves it out.
    public func minutes(ownParentDurationsMs: [Int] = []) -> Int {
        ItemListeningChoices.marginsOnlyMinutes(margins, ownParentDurationsMs: ownParentDurationsMs)
    }

    /// The length of each distinct own Margin the run plays before a reply, for `minutes`. Only a spoken parent whose
    /// recording is on this phone plays (`hasVoice`), as in the review's playlist. A Margin keeps no recording length,
    /// so it is the aligned transcript's last word, else the words at the on-device voice's pace.
    public func ownParentLengthsMs(ownMargins: [Interjection], hasVoice: (Interjection) -> Bool) -> [Int] {
        var seen = Set<String>()
        return margins.compactMap(\.replyToYouParentId).filter { seen.insert($0).inserted }.compactMap { parentId in
            guard let parent = ownMargins.first(where: { $0.id == parentId }), parent.audioPath != nil, hasVoice(parent) else {
                return nil
            }
            if let lastEndMs = parent.alignedTranscript?.segments.map(\.endMs).max(), lastEndMs > 0 { return lastEndMs }
            return ItemListeningChoices.spokenLengthMs(of: parent.displayText ?? parent.transcript ?? "")
        }
    }
}

/// One catch-up run's life, from the tap to the caught-up card (#4785). A value: the app feeds it events and draws
/// what it says. It never reads the store.
public struct CatchUpRun: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The run is playing.
        case running
        /// The last Margin's natural end came. `stillNew` is how many of the run's friend Margins are still unheard (they
        /// couldn't play, or were skipped before their voice started); the listener's own parent steps never count.
        case ended(stillNew: Int)
        /// It ended early (Stop Margins, a Timeline jump, another item): no card, and the rest stay new.
        case stopped
        /// The card was put away.
        case dismissed
    }

    public enum Event: Equatable, Sendable {
        case completed(stillNew: Int)
        case stopped
        case dismissed
        case play
        case scrub
        case recordingStarted
        case otherItemOpened
    }

    public let itemId: String
    /// The friend Margins the run plays, by id (`SharedMarginReview.Entry.marginId`). The app counts which are still new.
    public let friendMarginIds: [String]
    /// The one sender's name, nil for several senders or none named.
    public let senderName: String?
    public let replyCount: Int
    public let allReplies: Bool
    public let noun: SourceNoun
    /// The item's title, for the line handed to the share sheet.
    public let title: String
    public private(set) var state: State = .running

    public init(
        itemId: String, friendMarginIds: [String], senderName: String?, replyCount: Int, allReplies: Bool,
        noun: SourceNoun, title: String
    ) {
        self.itemId = itemId
        self.friendMarginIds = friendMarginIds
        self.senderName = senderName
        self.replyCount = replyCount
        self.allReplies = allReplies
        self.noun = noun
        self.title = title
    }

    public init(itemId: String, catchUp: ConversationCatchUp, friendMarginIds: [String], noun: SourceNoun, title: String) {
        self.init(
            itemId: itemId, friendMarginIds: friendMarginIds, senderName: catchUp.senderName, replyCount: catchUp.replyCount,
            allReplies: catchUp.allReplies, noun: noun, title: title)
    }

    public var isRunning: Bool { state == .running }

    /// Feeds one event. While the run plays, only its natural end and an early end count: a pause, or a recording that
    /// starts mid-run, belongs to the review. Once the card shows, any of Dismiss, Play, a scrub or Skim, a recording
    /// starting or another item puts it away. Stopped and dismissed are final.
    public mutating func handle(_ event: Event) {
        switch (state, event) {
        case (.running, .completed(let stillNew)): state = .ended(stillNew: max(0, stillNew))
        case (.running, .stopped), (.running, .otherItemOpened): state = .stopped
        case (.running, _): break
        case (.ended, .completed), (.ended, .stopped): break
        case (.ended, _): state = .dismissed
        case (.stopped, _), (.dismissed, _): break
        }
    }

    /// The caught-up card, only while the run has ended and nothing put it away.
    public var card: PinnedMarginCard? {
        guard case .ended(let stillNew) = state else { return nil }
        return PinnedMarginCard(
            subject: .friend(senderName),
            stage: .caughtUp(stillNew: stillNew, allReplies: allReplies, shareText: shareText),
            noun: noun)
    }

    /// The one line "Let Cole know" hands to the share sheet: no link and no app name.
    public var shareText: String {
        let what: String
        if replyCount == 0 {
            what = "new Margins"
        } else {
            what = replyCount == 1 ? "reply" : "replies"
        }
        return "Heard your \(what) on \u{201C}\(title)\u{201D}."
    }
}
