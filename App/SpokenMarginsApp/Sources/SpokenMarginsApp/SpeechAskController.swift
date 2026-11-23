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
    /// iOS's own prompt. Injected so tests never raise it.
    private let askSystem: @Sendable () async -> Void
    private(set) var ask: SpeechRecognitionAsk
    private(set) var waiting: SpeechAskWaitingList
    private var reAskShownThisLaunch = false
    private var announcedForThisAsk = false
    /// Nil while no card is due. The slot and the list draw it only on their own surface.
    @Published private(set) var cardSurface: Surface?

    init(
        defaults: UserDefaults = .standard,
        access: @escaping () -> SpeechRecognitionAccessState = { SpeechRecognitionAccess.state },
        isSuppressed: @escaping () -> Bool = { Gate1AppModel.isRunningUnitTests || UITestingHooks.suppressesFirstRun },
        askSystem: @escaping @Sendable () async -> Void = { _ = await SpeechAuthorizationAsk.requestFromSystem() }
    ) {
        self.defaults = defaults
        self.access = access
        self.isSuppressed = isSuppressed
        self.askSystem = askSystem
        let waiting = SpeechAskWaitingList(stored: defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
        self.waiting = waiting
        let stored = defaults.string(forKey: SpeechRecognitionAsk.storageKey)
        let carried = SpeechRecognitionAsk.answerToCarryIntoLaunch(stored: stored, access: access())
        if carried != stored { defaults.removeObject(forKey: SpeechRecognitionAsk.storageKey) }
        ask = SpeechRecognitionAsk(storedAnswer: carried, hasSavedSpokenMargin: waiting.hasWaitingMargin)
        // An unanswered card comes back when the slot is free, including after a relaunch.
        if ask.isOwed(access: access()) { cardSurface = .now }
    }

    /// Closes iOS's prompt until the listener's Yes, for every transcription client at once. Called first thing at launch,
    /// before anything can transcribe. Reads the stored answer each time, so Yes opens it with no other step.
    nonisolated static func installGate() {
        // A Yes that iOS never answered (closed while its prompt was up) is dropped first, so the card returns and the
        // prompt cannot arrive in the middle of the next save.
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: SpeechRecognitionAsk.storageKey)
        if SpeechRecognitionAsk.answerToCarryIntoLaunch(stored: stored, access: SpeechRecognitionAccess.state) != stored {
            defaults.removeObject(forKey: SpeechRecognitionAsk.storageKey)
        }
        SpeechAuthorizationAsk.setMayAskSystem {
            SpeechRecognitionAsk(storedAnswer: UserDefaults.standard.string(forKey: SpeechRecognitionAsk.storageKey))
                .mayAskSystem(access: .notDetermined)
        }
    }

    // MARK: What the screens ask

    /// Readable off the main actor (rows are plain values): the stored waiting list and iOS's answer, no controller state.
    /// `defaults` and `access` are injectable so a test never reads the real ones.
    nonisolated static func marginIsWaitingForAnswer(
        _ marginIdentity: String,
        defaults: UserDefaults = .standard,
        access: SpeechRecognitionAccessState = SpeechRecognitionAccess.state
    ) -> Bool {
        SpeechAskWaitingList(stored: defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
            .isWaiting(marginIdentity, access: access)
    }

    /// The cheap answer comes first and `slotIsFree` is lazy: the Now pane redraws on every playback tick, and building the
    /// pinned card is not free, so nothing is read while no card is due.
    func isCardShowing(on surface: Surface = .now, slotIsFree: @autoclosure () -> Bool) -> Bool {
        cardSurface == surface && !isSuppressed() && access() == .notDetermined && slotIsFree()
    }

    /// The first card is owed and unanswered: iOS undecided, a spoken Margin saved, no answer yet. It holds through a
    /// relaunch (the waiting list arms it), so #4672's sheet waits on this and not on whether the card is on screen now.
    var isOutstanding: Bool { ask.isOwed(access: access()) }

    /// Whether this Margin is a spoken one still waiting for the listener's answer: it reads "No transcript yet.".
    func isWaiting(marginIdentity: String) -> Bool {
        waiting.isWaiting(marginIdentity, access: access())
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
            if ask.isOwed(access: access()) { cardSurface = .now }
        }
    }

    /// The listener tapped Get Transcript on a Margin that waits. It is a direct request, so it always gets somewhere while
    /// iOS is undecided: Yes already said (iOS's prompt lost) asks iOS again; otherwise the card shows right here, whatever
    /// the once-per-launch limit on re-asks says. Once iOS has decided it settles the waiting Margins.
    func getTranscript(on surface: Surface, model: Gate1AppModel?) {
        switch ask.getTranscriptStep(access: access()) {
        case .askSystem: _ = yes(model: model)
        case .showCard: cardSurface = surface
        case .settle: reconcile(model: model)
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

    /// The listener left the Margins tab or the Margin's screen where the card was drawn without answering. It goes back to
    /// Now, which is the one surface that always draws it, so it can't vanish for the rest of the launch.
    func surfaceLeft(_ surface: Surface) {
        guard cardSurface == surface, surface != .now,
              ask.cardStaysOnNowAfterSurfaceLeft(access: access()) else { return }
        cardSurface = .now
    }

    /// True once per ask: VoiceOver hears the card when it first appears, not again each time the slot frees up. A Not now
    /// that is re-asked later is a new ask.
    func shouldAnnounceCard() -> Bool {
        defer { announcedForThisAsk = true }
        return !announcedForThisAsk
    }

    // MARK: What the listener taps

    func notNow() {
        record(.notNow)
    }

    /// Yes: the app has asked, so iOS may now. Allow transcribes what waited; Don't Allow leaves it reading as #268 says.
    @discardableResult
    func yes(model: Gate1AppModel?) -> Task<Void, Never> {
        record(.yes)
        return Task { [weak self, weak model, askSystem] in
            await askSystem()
            guard let self else { return }
            MainThreadOperationLabels.shared.scoped("speechAsk.yes") { self.reconcile(model: model) } // so a slow settle names its step (#2256)
        }
    }

    private func record(_ answer: SpeechRecognitionAsk.Answer) {
        ask.answered(answer)
        announcedForThisAsk = false
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
            let heldSources = SpeechAuthorizationAsk.takeHeldSourceItems()
            guard !identities.isEmpty || !heldSources.isEmpty else { return }
            clearWaiting()
            if !identities.isEmpty { model?.retryWaitingTranscriptions(identities: identities) }
            if !heldSources.isEmpty { model?.retryHeldSourceTranscriptions(itemIds: heldSources) }
        case .denied, .restricted:
            _ = SpeechAuthorizationAsk.takeHeldSourceItems()
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
