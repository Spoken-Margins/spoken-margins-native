import Foundation

/// #4715: what a transcription that goes through the Speech Recognition gate is for. The gate
/// (`SpeechAuthorizationAsk.requireAuthorized(for:)`) takes one with no default, and so does every transcription client
/// method that reaches it, so a new caller that doesn't say what it is for doesn't compile. When the gate holds the work
/// (`speech_recognition_not_yet_asked`) it reports the purpose to one sink, the app's speech ask, which decides from the
/// purpose alone whether the card is owed and how the work starts again after Allow. No caller has to remember to arm the
/// card (the audit on #5124 found three that didn't, one after another).
///
/// The card is owed for a spoken Margin from any surface (the #4715 Design ties it to saving one), for a spoken note (the
/// listener's own recording; director's Default taken on #4715, 2026-11-23), for a friend's packet placement (the
/// same Default) and for an episode map the listener asked for (on `main`, iOS asked at that tap; the pre-audit on
/// #5124). The other purposes wait quietly and are retried whenever the listener does allow.
public enum HeldTranscription: String, Sendable, CaseIterable {
    /// A spoken Margin saved in the player, or by a Shortcut onto a Library item (`Gate1AppModel` transcription).
    case playerMargin
    /// A spoken Margin recorded on the phone in a live session or with Record a Margin (`LiveSessionSpokenCapture`).
    case liveSessionMargin
    /// A spoken Margin recorded on the Apple Watch (`WatchMarginReceiver`).
    case watchMargin
    /// A spoken Margin from the "Add voice Margin" Shortcut, filed into a live or quick session (`AddVoiceMarginAction`).
    case shortcutMargin
    /// A friend's podcast packet: a transient transcript of the listener's copy places the Margins acoustic evidence
    /// could not (`ImportedPodcastPlacementCoordinator.scheduleTransientTranscript`).
    case friendPacketPlacement
    /// The private episode map and Listening Map (`EpisodeMapPreparer`) prepared in the background, unasked.
    case episodeMap
    /// The same map when the listener asked for it (an explicit policy: Prepare Listening Map, or the download they
    /// started for one finishing). With no spoken Margin it is the only way to reach Allow, so it owes the card.
    case listenerEpisodeMap
    /// The source words around a spoken Margin (`Gate1AppModel+SourceWindowContext`).
    case sourceWindow
    /// The text-to-time map for an article's publisher audio (`PublisherAudioTextMapper`), which checks iOS's answer
    /// before it transcribes and so waits rather than throws.
    case publisherTextMap
    /// The few words the Just Heard peek shows (`Gate1AppModel+JustHeardPeek`). Transient: the listener peeks again.
    case justHeardPeek
    /// A take of a spoken note (`SystemSpokenNoteTranscriber`). Not a Margin, but the listener's own recording, so it
    /// owes the card in the Margins words and every note's takes with no words are swept after Allow (director's Default
    /// taken on #4715, 2026-11-23). The note also asks again for a take with no words when it is opened.
    case spokenNote

    /// How held work of this purpose starts again after Allow.
    public enum Retry: Equatable, Sendable {
        /// The caller registers its own retry (`HeldTranscriptionRetries.hold`), because only it knows the item or key.
        case callerRegisters
        /// The Margin is put on the stored waiting list (`SpeechAskWaitingList`) by the player's failure path.
        case waitingList
        /// One sweep of the live sessions' spoken Margins that have no words yet, registered by the sink itself
        /// (`HeldTranscriptionRetries.reported`), so `try?` at the caller loses nothing.
        case liveSessionSweep
        /// One sweep of the spoken notes' takes that have no words yet (`SpokenNoteTranscriptSweep`), registered by the
        /// sink itself, so the recorder's closed screen or a relaunch loses nothing.
        case spokenNoteSweep
        /// Nothing to retry: the work was transient, or its owner asks again on its own.
        case none

        /// The UserDefaults key (a Bool) that carries a held sweep into the next launch, or nil for a retry that lives
        /// elsewhere (the waiting list, the caller) or nowhere. A sweep's held work is on disk with no words, and it can
        /// be held while the app is in the background, so the next launch reads this to owe the card and sweep after Allow.
        public var heldAcrossLaunchKey: String? {
            switch self {
            case .liveSessionSweep: SpeechRecognitionAsk.liveSessionMarginHeldKey
            case .spokenNoteSweep: SpeechRecognitionAsk.spokenNoteHeldKey
            case .callerRegisters, .waitingList, .none: nil
            }
        }
    }

    /// A spoken Margin, from whichever surface saved it.
    public var isSpokenMargin: Bool {
        switch self {
        case .playerMargin, .liveSessionMargin, .watchMargin, .shortcutMargin: true
        case .friendPacketPlacement, .episodeMap, .listenerEpisodeMap, .sourceWindow, .publisherTextMap, .justHeardPeek, .spokenNote: false
        }
    }

    /// The listener's own recording: a spoken Margin from any surface, or a spoken note. Its hold owes the card in the
    /// Margins words.
    public var isListenersRecording: Bool { isSpokenMargin || self == .spokenNote }

    /// Whether this held work makes the in-app card owed.
    public var makesAskOwed: Bool { isListenersRecording || self == .friendPacketPlacement || self == .listenerEpisodeMap }

    /// The purposes whose held work is carried into the next launch, one per stored key: the purpose the launch reports
    /// again to owe the card and register the sweep.
    public static var heldAcrossLaunch: [(key: String, purpose: HeldTranscription)] {
        var seen = Set<String>()
        return allCases.compactMap { purpose in
            guard let key = purpose.retry.heldAcrossLaunchKey, seen.insert(key).inserted else { return nil }
            return (key, purpose)
        }
    }

    public var retry: Retry {
        switch self {
        case .playerMargin: .waitingList
        case .liveSessionMargin, .watchMargin, .shortcutMargin: .liveSessionSweep
        case .friendPacketPlacement, .episodeMap, .listenerEpisodeMap, .sourceWindow, .publisherTextMap: .callerRegisters
        case .spokenNote: .spokenNoteSweep
        case .justHeardPeek: .none
        }
    }

    /// The error a transcription client throws while the ask has not been made.
    public static func isHold(_ error: Error) -> Bool {
        TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: String(describing: error))
    }
}

/// The work held for the listener's answer, each piece once (by kind and key, the latest retry kept), oldest first.
/// On Allow every retry runs, so no held path depends on its own bookkeeping to start again (the round-1 gap was a
/// retry that needed `requestedURL`). On a decided no they are dropped. In memory only: a relaunch starts each path
/// again on its own, and it meets the hold again if the answer is still open.
@MainActor
public final class HeldTranscriptionRetries {
    private struct Entry {
        let kind: HeldTranscription
        let key: String
        let retry: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private let liveSessionSweep: @MainActor () -> Void
    private let spokenNoteSweep: @MainActor () -> Void

    /// The key the live-session sweep is held under: one sweep covers every live-session, Watch and Shortcut Margin.
    public static let liveSessionSweepKey = "live-session-spoken-margins"
    /// The key the spoken-note sweep is held under: one sweep covers every note's takes with no words.
    public static let spokenNoteSweepKey = "spoken-note-takes"

    /// `liveSessionSweep` transcribes every live-session spoken Margin that has no words yet
    /// (`LiveSessionSpokenMarginSweep`); `spokenNoteSweep` every spoken note take with none (`SpokenNoteTranscriptSweep`).
    /// Each runs once on Allow however many of its kind were held.
    public init(
        liveSessionSweep: @escaping @MainActor () -> Void = {},
        spokenNoteSweep: @escaping @MainActor () -> Void = {}
    ) {
        self.liveSessionSweep = liveSessionSweep
        self.spokenNoteSweep = spokenNoteSweep
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The kinds held now, in the order first held.
    public var heldKinds: [HeldTranscription] {
        var seen = Set<HeldTranscription>()
        return entries.map(\.kind).filter { seen.insert($0).inserted }
    }

    /// Holds `retry` until the listener answers. A second hold of the same kind and key replaces the first's retry but
    /// keeps its place.
    public func hold(_ kind: HeldTranscription, key: String, retry: @escaping @MainActor () -> Void) {
        let entry = Entry(kind: kind, key: key, retry: retry)
        if let index = entries.firstIndex(where: { $0.kind == kind && $0.key == key }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// The gate held work for `purpose`. Registers the retry the sink owns: the live-session sweep for a live-session,
    /// Watch or Shortcut spoken Margin, the spoken-note sweep for a spoken note. Every other purpose's retry is the
    /// caller's or the waiting list's.
    public func reported(_ purpose: HeldTranscription) {
        switch purpose.retry {
        case .liveSessionSweep: hold(.liveSessionMargin, key: Self.liveSessionSweepKey, retry: liveSessionSweep)
        case .spokenNoteSweep: hold(.spokenNote, key: Self.spokenNoteSweepKey, retry: spokenNoteSweep)
        case .callerRegisters, .waitingList, .none: return
        }
    }

    /// Forgets the held work of `kind` under `keys`, because another retry already covers it. A spoken Margin on the
    /// waiting list gets its source window after its own transcription; retrying the window first would race the note for
    /// the speech service.
    public func drop(_ kind: HeldTranscription, keys: Set<String>) {
        entries.removeAll { $0.kind == kind && keys.contains($0.key) }
    }

    /// Settles the held work against iOS's answer: allowed runs every retry, oldest first; a decided no drops them;
    /// undecided keeps them. Returns how many retries ran.
    @discardableResult
    public func settle(access: SpeechRecognitionAccessState) -> Int {
        switch access {
        case .notDetermined:
            return 0
        case .denied, .restricted:
            entries.removeAll()
            return 0
        case .authorized:
            let due = entries
            entries.removeAll()
            for entry in due { entry.retry() }
            return due.count
        }
    }
}
