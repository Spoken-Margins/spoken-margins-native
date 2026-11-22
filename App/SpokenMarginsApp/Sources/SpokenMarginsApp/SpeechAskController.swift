import Foundation
import SessionKit
import SessionKitAudio

/// #4715 / #5016: carries `SpeechRecognitionAsk`'s decisions out. It keeps the listener's answer and the waiting list in
/// UserDefaults, says whether the card is up and where, closes iOS's prompt until Yes, and on an answer transcribes (or
/// settles) the Margins that waited. It is its own object, not state on `Gate1AppModel`, so the model does not grow: the
/// model calls it from the save, the failure path and the screens that reach for text.
@MainActor
final class SpeechAskController: ObservableObject {
    /// Where the card is drawn. A re-ask shows where the listener reached for text (Design section 2).
    enum Surface: Equatable {
        case now, margins, detail
    }

    static let shared = SpeechAskController()

    private let defaults: UserDefaults
    private let access: () -> SpeechRecognitionAccessState
    private let isSuppressed: () -> Bool
    private(set) var ask: SpeechRecognitionAsk
    private(set) var waiting: SpeechAskWaitingList
    private var reAskShownThisLaunch = false
    /// Nil while no card is due. The slot and the list draw it only on their own surface.
    @Published private(set) var cardSurface: Surface?

    init(
        defaults: UserDefaults = .standard,
        access: @escaping () -> SpeechRecognitionAccessState = { SpeechRecognitionAccess.state },
        isSuppressed: @escaping () -> Bool = { Gate1AppModel.isRunningUnitTests || UITestingHooks.suppressesFirstRun }
    ) {
        self.defaults = defaults
        self.access = access
        self.isSuppressed = isSuppressed
        let waiting = SpeechAskWaitingList(stored: defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
        self.waiting = waiting
        ask = SpeechRecognitionAsk(
            storedAnswer: defaults.string(forKey: SpeechRecognitionAsk.storageKey),
            hasSavedSpokenMargin: waiting.hasWaitingMargin)
        // An unanswered card comes back when the slot is free, including after a relaunch.
        if ask.isOwed(access: access()) { cardSurface = .now }
    }

    /// Closes iOS's prompt until the listener's Yes, for every transcription client at once. Called first thing at launch,
    /// before anything can transcribe. Reads the stored answer each time, so Yes opens it with no other step.
    nonisolated static func installGate() {
        SpeechAuthorizationAsk.setMayAskSystem {
            SpeechRecognitionAsk(storedAnswer: UserDefaults.standard.string(forKey: SpeechRecognitionAsk.storageKey))
                .mayAskSystem(access: .notDetermined)
        }
    }

    // MARK: What the screens ask

    /// Readable off the main actor (rows are plain values): the stored waiting list and iOS's answer, no controller state.
    nonisolated static func marginIsWaitingForAnswer(_ marginIdentity: String) -> Bool {
        SpeechAskWaitingList(stored: UserDefaults.standard.stringArray(forKey: SpeechAskWaitingList.storageKey)).contains(marginIdentity)
            && SpeechRecognitionAccess.state == .notDetermined
    }

    /// The cheap answer comes first and `slotIsFree` is lazy: the Now pane redraws on every playback tick, and building the
    /// pinned card is not free, so nothing is read while no card is due.
    func isCardShowing(on surface: Surface = .now, slotIsFree: @autoclosure () -> Bool) -> Bool {
        cardSurface == surface && !isSuppressed() && access() == .notDetermined && slotIsFree()
    }

    /// Whether this Margin is a spoken one still waiting for the listener's answer: it reads "No transcript yet.".
    func isWaiting(marginIdentity: String) -> Bool {
        waiting.contains(marginIdentity) && access() == .notDetermined
    }

    // MARK: What the app tells it

    /// A spoken Margin was saved (a written one brings no card).
    func spokenMarginSaved(isWritten: Bool) {
        guard let moment = SpeechRecognitionAsk.Moment.forSavedMargin(isWritten: isWritten, hearItLandWillRun: false) else { return }
        if ask.cardDue(at: moment, access: access(), shownThisLaunchForReAsk: false) { cardSurface = .now }
    }

    /// The Margin's transcription met the hold: it waits for the answer. `marginIdentity` is `Gate1AppModel.marginIdentity`.
    func marginIsWaiting(marginIdentity: String) {
        guard waiting.add(marginIdentity) else { return }
        defaults.set(waiting.stored, forKey: SpeechAskWaitingList.storageKey)
        // A relaunch arms the card from this list; this launch is armed by the save, but a Margin that arrives here alone
        // (a retry) arms it too.
        if cardSurface == nil, ask.answer == .unanswered {
            _ = ask.cardDue(at: .spokenMarginSaved(hearItLandWillRun: true), access: access(), shownThisLaunchForReAsk: false)
        }
    }

    /// The listener reached for text: searched their Margins, copied one as text, or tapped Get Transcript. A re-ask shows
    /// once per launch at most, where they are.
    func reachedForText(on surface: Surface) {
        let wasNotNow = ask.answer == .notNow
        guard ask.cardDue(at: .reachedForText, access: access(), shownThisLaunchForReAsk: reAskShownThisLaunch) else { return }
        if wasNotNow { reAskShownThisLaunch = true }
        cardSurface = surface
    }

    // MARK: What the listener taps

    func notNow() {
        record(.notNow)
    }

    /// Yes: the app has asked, so iOS may now. Allow transcribes what waited; Don't Allow leaves it reading as #268 says.
    func yes(model: Gate1AppModel) {
        record(.yes)
        Task { [weak self, weak model] in
            _ = await SpeechAuthorizationAsk.requestFromSystem()
            guard let self else { return }
            self.reconcile(model: model)
        }
    }

    private func record(_ answer: SpeechRecognitionAsk.Answer) {
        ask.answered(answer)
        defaults.set(ask.storedAnswer, forKey: SpeechRecognitionAsk.storageKey)
        cardSurface = nil
    }

    /// Settles the waiting list against iOS's answer now: allowed, so each waiting Margin is transcribed, oldest first;
    /// decided no, so the list is cleared and they read as #268 says. Undecided leaves it alone. Runs on Yes and when the
    /// Now pane appears, so a Margin that waited through a relaunch, or an answer given in iOS Settings, is settled too.
    func reconcile(model: Gate1AppModel?) {
        switch access() {
        case .notDetermined:
            return
        case .authorized:
            let identities = waiting.ids
            guard !identities.isEmpty else { return }
            clearWaiting()
            model?.retryWaitingTranscriptions(identities: identities)
        case .denied, .restricted:
            guard waiting.hasWaitingMargin else { return }
            clearWaiting()
            model?.refreshMarginRowsInBackground()
        }
        cardSurface = nil
    }

    private func clearWaiting() {
        waiting.clear()
        defaults.removeObject(forKey: SpeechAskWaitingList.storageKey)
    }
}
