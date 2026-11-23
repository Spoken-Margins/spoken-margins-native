import Foundation

/// #4715: a piece of transcription work that met the hold on iOS's Speech Recognition prompt
/// (`speech_recognition_not_yet_asked`). Every caller of the transcription clients that can meet the hold names itself
/// here, so the rule "held work makes the ask owed (or not) and is retried after Allow" covers each one by name.
///
/// Only a friend's packet placement makes the ask owed (director's Default taken on #4715, 2026-11-23): a listener who
/// has never recorded has no other way to reach Allow, and their friend's Margins would otherwise stay at the sender's
/// time. The other kinds wait quietly and are retried whenever the listener does allow.
public enum HeldTranscription: String, Sendable, CaseIterable {
    /// A friend's podcast packet: a transient transcript of the listener's copy places the Margins acoustic evidence
    /// could not (`ImportedPodcastPlacementCoordinator.scheduleTransientTranscript`).
    case friendPacketPlacement
    /// The private episode map and Listening Map (`EpisodeMapPreparer`).
    case episodeMap
    /// The source words around a spoken Margin (`Gate1AppModel+SourceWindowContext`).
    case sourceWindow
    /// The text-to-time map for an article's publisher audio (`PublisherAudioTextMapper`), which checks iOS's answer
    /// before it transcribes and so waits rather than throws.
    case publisherTextMap

    /// Whether this held work makes the in-app card owed.
    public var makesAskOwed: Bool { self == .friendPacketPlacement }

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

    public init() {}

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
