import Foundation

/// Which Library items audio preparation works on, and which stored jobs still belong in its queue (#883).
///
/// The rule had no single owner. Automatic While Charging preparation took every Library item that has text,
/// so a podcast's transcript or show notes were queued to be read aloud, while the opening-buffer pass already
/// skipped them. And a trashed item kept its jobs, so they went on counting toward the Library's "queued"
/// total, and could still be rendered, until the item was deleted for good.
public enum LibraryAudioPreparationAdmission {
    /// True for media that plays its own audio: a podcast episode, a stream, a page's video. Its text (a
    /// transcript, show notes) is there to read along with, not to be narrated.
    public static func playsItsOwnAudio(_ item: some LibraryItemFields) -> Bool {
        if item.mediaType == TargetType.browserOwnedMedia.rawValue { return true }
        switch item.media?.sourceType {
        case .nativeMediaFile, .remoteStream, .browserOwnedMedia: return true
        case .none, .generatedTTSRealtime, .generatedTTSPrerendered: return false
        }
    }

    /// Whether the listener has finished the item, marked it finished or played it to the end.
    public static func isFinished(_ item: some LibraryItemFields, sessions: [Session]) -> Bool {
        item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(sessions)
    }

    /// Whether automatic preparation, which the listener didn't ask for, takes the item: text to narrate that is
    /// still in the Library and not finished. (Whether it has any text is the caller's check, because a PDF's
    /// listenable text comes from its document.)
    public static func admitsAutomatically(_ item: some LibraryItemFields, sessions: [Session]) -> Bool {
        item.deletedAt == nil && !playsItsOwnAudio(item) && !isFinished(item, sessions: sessions)
    }

    /// The stored jobs that no longer belong in the queue, by id. A job for an item that is trashed or gone is
    /// stale whoever asked for it. A job the listener didn't ask for (opening buffers, While Charging) is also
    /// stale once its item is finished or plays its own audio. An explicit "Make available offline" request
    /// stays, even for a finished item.
    public static func staleJobIds<Fields: LibraryItemFields>(
        _ jobs: [AudioPreparationJob],
        items: [Fields],
        sessionsByItemId: [String: [Session]]
    ) -> [String] {
        let itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return jobs.filter { job in
            guard let item = itemsById[job.itemId], item.deletedAt == nil else { return true }
            guard job.policy != .explicit else { return false }
            return !admitsAutomatically(item, sessions: sessionsByItemId[item.id] ?? [])
        }.map(\.id)
    }
}
