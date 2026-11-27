import Foundation

/// #4715 / #5016: when the app asks the listener about Speech Recognition, in one plain line, so iOS's own prompt never
/// arrives in the middle of a save with nothing from the app first. Pure: the app reads iOS's answer and the listener's
/// taps and this says whether the card is due and whether iOS may be asked.
///
/// The card follows `docs/design/first-run.md` section 3, step 6. It is due while iOS says "not determined" and the
/// listener hasn't answered it, once they have saved a spoken Margin. A written Margin never brings it: there is no audio
/// to transcribe. A friend's packet whose placement met the hold brings it too, in its own words, so a listener who has
/// never recorded can still reach Allow (director's Default taken on #4715, 2026-11-23).
public struct SpeechRecognitionAsk: Equatable, Sendable {
    public enum Answer: String, Sendable {
        case unanswered, notNow, yes
    }

    public enum Moment: Sendable, Equatable {
        /// A spoken Margin was saved. `hearItLandWillRun` is #4713's plan: when true the card waits for its end.
        case spokenMarginSaved(hearItLandWillRun: Bool)
        case hearItLandEnded
        /// The listener reached for text: searched their Margins, copied one as text, or tapped Get Transcript.
        case reachedForText

        /// The moment a saved Margin is, or nil for a written one (no audio, so nothing to ask about).
        public static func forSavedMargin(isWritten: Bool, hearItLandWillRun: Bool) -> Moment? {
            isWritten ? nil : .spokenMarginSaved(hearItLandWillRun: hearItLandWillRun)
        }
    }

    /// UserDefaults key. Older builds ignore it.
    public static let storageKey = "speechRecognitionAskV1"
    /// UserDefaults key, a Bool: a live-session, Watch or Shortcut spoken Margin met the hold and the listener has not
    /// answered. Those Margins live in the live-session files, not the waiting list, and the Watch and the Shortcut can
    /// meet the hold while the app runs in the background, so the next launch reads this to owe the card and to sweep
    /// them after Allow. Older builds ignore it.
    public static let liveSessionMarginHeldKey = "speechAskLiveSessionMarginHeldV1"
    /// UserDefaults key, a Bool: a spoken note take met the hold and the listener has not answered. Like
    /// `liveSessionMarginHeldKey`: the take is in its note with no words, so the next launch reads this to owe the card
    /// and to sweep the notes after Allow. Older builds ignore it.
    public static let spokenNoteHeldKey = "speechAskSpokenNoteHeldV1"

    public private(set) var answer: Answer
    /// A spoken Margin has been saved (or a spoken note's take held), so the card is owed until answered. Survives a
    /// relaunch through the waiting list (a player Margin), `liveSessionMarginHeldKey` (a live-session, Watch or Shortcut
    /// Margin) or `spokenNoteHeldKey` (a spoken note).
    private var hasSavedSpokenMargin: Bool
    /// A friend's packet placement met the hold. In memory: after a relaunch it is set again only when placement meets the
    /// hold again.
    private var friendPlacementHeld = false
    /// An episode map the listener asked for met the hold. In memory, like `friendPlacementHeld`.
    private var listenerMapHeld = false
    /// A spoken save's hear it land playback is due or running, so the card waits for `.hearItLandEnded` (#4713, #5423).
    /// Set by `.spokenMarginSaved(hearItLandWillRun: true)` and cleared by `.hearItLandEnded`. In memory: a relaunch ends
    /// any playback, so the card is free again.
    public private(set) var waitsForHearItLand = false

    /// `hasSavedSpokenMargin` is true at launch when a spoken Margin is on the waiting list.
    public init(storedAnswer: String?, hasSavedSpokenMargin: Bool = false) {
        answer = storedAnswer.flatMap(Answer.init(rawValue:)) ?? .unanswered
        self.hasSavedSpokenMargin = hasSavedSpokenMargin
    }

    public var storedAnswer: String { answer.rawValue }

    /// The answer to carry into a launch. A stored Yes while iOS still says "not determined" means the app was closed while
    /// iOS's prompt was up: the listener never answered it. That Yes is dropped, so the card comes back and iOS's prompt
    /// stays closed until they say Yes again, and it never arrives in the middle of a later save (#5016). Any other pair is
    /// kept as stored.
    public static func answerToCarryIntoLaunch(stored: String?, access: SpeechRecognitionAccessState) -> String? {
        if stored == Answer.yes.rawValue, access == .notDetermined { return nil }
        return stored
    }

    /// Get Transcript is a direct request, not a nag: it always gets somewhere while iOS has not decided.
    public enum GetTranscriptStep: Equatable, Sendable {
        /// The listener said Yes but iOS has not been answered (or was closed on): ask iOS now.
        case askSystem
        /// Show the card where they tapped, whatever the once-per-launch limit says.
        case showCard
        /// iOS has decided: settle the Margins that waited.
        case settle
    }

    public func getTranscriptStep(access: SpeechRecognitionAccessState) -> GetTranscriptStep {
        guard access == .notDetermined else { return .settle }
        return answer == .yes ? .askSystem : .showCard
    }

    /// Only the listener's Yes lets a transcription client call iOS's prompt, and only while iOS has not decided.
    public func mayAskSystem(access: SpeechRecognitionAccessState) -> Bool {
        answer == .yes && access == .notDetermined
    }

    /// The first card is owed: asked of nobody yet, a spoken Margin saved or a friend's placement held, iOS undecided. The
    /// Now pane shows it whenever its slot is free, including after a relaunch.
    public func isOwed(access: SpeechRecognitionAccessState) -> Bool {
        access == .notDetermined && answer == .unanswered && hasReasonToAsk
    }

    /// Whether an owed card may go up now, when work meets the hold: owed, and no hear it land playback holds it back.
    /// The save's transcription meets the hold during its own playback, so a hold must not let the card out early (#5423);
    /// the playback's end lets it out (`cardDue(at: .hearItLandEnded, ...)`).
    public func mayShowOwedCard(access: SpeechRecognitionAccessState) -> Bool {
        isOwed(access: access) && !waitsForHearItLand
    }

    private var hasReasonToAsk: Bool { hasSavedSpokenMargin || friendPlacementHeld || listenerMapHeld }

    /// Transcription work met the hold. The listener's own recording (a spoken Margin from any surface, or a spoken
    /// note) owes the card in the Margins words; a friend's packet placement gives it its own reason. The rest wait
    /// quietly for whatever answer the listener gives.
    public mutating func transcriptionHeld(_ kind: HeldTranscription) {
        if kind.isListenersRecording {
            hasSavedSpokenMargin = true
        } else if kind == .listenerEpisodeMap {
            listenerMapHeld = true
        } else if kind.makesAskOwed {
            friendPlacementHeld = true
        }
    }

    /// What the card says. The Margins words fit anyone who has saved a spoken Margin; a listener whose only reason is a
    /// friend's packet has no Margins of their own to get as text, so they hear why their friend's need it.
    public struct CardWording: Equatable, Sendable {
        public let headline: String
        public let detail: String?
        public let yesAccessibilityLabel: String

        public static let margins = CardWording(
            headline: "Want your Margins as text too?",
            detail: "Then you can search them and copy them into your notes.",
            yesAccessibilityLabel: "Yes, get my Margins as text")
        public static let friendPlacement = CardWording(
            headline: "Your friend's Margins land at the right moment if you allow speech recognition.",
            detail: nil,
            yesAccessibilityLabel: "Yes, allow speech recognition")
        public static let listeningMap = CardWording(
            headline: "This episode's Listening Map needs speech recognition.",
            detail: nil,
            yesAccessibilityLabel: "Yes, allow speech recognition")
    }

    /// The Margins words once the listener has a spoken Margin; otherwise the reason they have, a friend's packet first.
    public var cardWording: CardWording {
        if hasSavedSpokenMargin { return .margins }
        if friendPlacementHeld { return .friendPlacement }
        return listenerMapHeld ? .listeningMap : .margins
    }

    /// Whether the card shows at `moment`. A save arms the card whatever the answer to whether it shows now.
    /// `shownThisLaunchForReAsk` limits a re-ask after Not now to once per launch.
    public mutating func cardDue(at moment: Moment, access: SpeechRecognitionAccessState, shownThisLaunchForReAsk: Bool) -> Bool {
        if case .spokenMarginSaved(let hearItLandWillRun) = moment {
            hasSavedSpokenMargin = true
            if hearItLandWillRun { waitsForHearItLand = true }
        }
        if case .hearItLandEnded = moment { waitsForHearItLand = false }
        guard access == .notDetermined else { return false }
        switch (moment, answer) {
        case (_, .yes):
            return false
        case (.spokenMarginSaved(let hearItLandWillRun), .unanswered):
            return !hearItLandWillRun
        case (.hearItLandEnded, .unanswered):
            return hasReasonToAsk
        case (.reachedForText, .unanswered):
            return hasReasonToAsk
        case (.reachedForText, .notNow):
            return !shownThisLaunchForReAsk
        case (.spokenMarginSaved, .notNow), (.hearItLandEnded, .notNow):
            return false
        }
    }

    /// The card was drawn where the listener reached for text (the Margins tab, a Margin's screen) and they left without
    /// answering. It goes back to the Now pane so it can't vanish for the rest of the launch. Not after a Yes or once iOS
    /// has decided.
    public func cardStaysOnNowAfterSurfaceLeft(access: SpeechRecognitionAccessState) -> Bool {
        access == .notDetermined && answer != .yes
    }

    public mutating func answered(_ answer: Answer) {
        self.answer = answer
    }
}

/// The ids of spoken Margins whose transcription met the hold on iOS's prompt, oldest first. Stored under
/// `speechAskWaitingMarginIdsV1`. On Allow they are transcribed in order; either answer clears the list. Each Margin is
/// stored as `failed`, so no database change is needed and the last shipped build opens it.
public struct SpeechAskWaitingList: Equatable, Sendable {
    public static let storageKey = "speechAskWaitingMarginIdsV1"

    public private(set) var ids: [String]

    public init(stored: [String]?) {
        var seen = Set<String>()
        ids = (stored ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public var stored: [String] { ids }
    public var hasWaitingMargin: Bool { !ids.isEmpty }

    public func contains(_ id: String) -> Bool { !id.isEmpty && ids.contains(id) }

    /// The Margin is a spoken one still waiting for the listener's answer: listed, and iOS has not decided.
    public func isWaiting(_ id: String, access: SpeechRecognitionAccessState) -> Bool {
        access == .notDetermined && contains(id)
    }

    /// False for an empty id or one already waiting.
    @discardableResult
    public mutating func add(_ id: String) -> Bool {
        guard !id.isEmpty, !ids.contains(id) else { return false }
        ids.append(id)
        return true
    }

    public mutating func clear() { ids.removeAll() }
}
