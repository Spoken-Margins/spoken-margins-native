import Foundation

// The store halves of three engine attach methods (#2509), built like `ListeningMapPersister`: each persister holds
// the repository and a copy of the few engine values its steps read, runs every store read, store write and heavy
// text step, and returns what the engine half needs. A caller runs `persist` off the main thread and hands the
// result to the matching `SessionEngine.attach...(_ persisted:)` on it. Step order and guards are the old methods'.

/// Saves an item as the Library stores it: never with the publisher's recording as its audio.
private func storedItem(_ item: Item, publisher: PublisherAudioPlayback?) -> Item {
    publisher?.stored(item) ?? item
}

// MARK: Prepared text audio

/// What `PreparedTextAudioPersister.persist` did. `updated` is nil when the guard refused and nothing was written.
public struct PersistedPreparedTextAudio: Sendable {
    /// The item as it was loaded, before the write.
    public let stored: Item
    public let updated: Item?
    public let prepared: PreparedTextAudio
}

/// Why a prepared-audio save was refused with nothing written.
public enum PreparedTextAudioRefusal: Error, Equatable, Sendable {
    /// A Stop, a failure or a new voice retired the manifest the audio was rendered under.
    case preparationRetired
}

/// What `PreparedTextAudioPersister.persistAssembly` did.
public enum PreparedAudioAssemblyAttach: Sendable {
    /// Saved, or the item is one that takes no generated audio (`updated` is nil); either way the engine half runs next.
    case attached(PersistedPreparedTextAudio)
    /// The preparation was retired, replaced or made for other text meanwhile; nothing was written.
    case dropped
}

public struct PreparedTextAudioPersister: Sendable {
    let repository: any SessionRepository
    let profile: RuntimeCapabilityProfile
    let currentMap: ListeningMap?
    let publisher: PublisherAudioPlayback?

    /// Loads the item, lets the guard decide, then writes the prepared audio's timeline and item.
    ///
    /// A caller that rendered the audio under a prepared-audio manifest passes its id. The write then also checks, in
    /// the same transaction, that a Stop, a failure or a new voice has not retired that manifest while this ran off the
    /// main thread (#2134), and throws `PreparedTextAudioRefusal.preparationRetired` with nothing written if it has.
    public func persist(itemId: String, prepared: PreparedTextAudio, manifestId: String? = nil) throws -> PersistedPreparedTextAudio {
        let item = try repository.loadItem(id: itemId)
        guard SessionEngine.shouldPrepareGeneratedTextAudio(for: item, profile: profile) else {
            return PersistedPreparedTextAudio(stored: item, updated: nil, prepared: prepared)
        }
        let updated = try write(prepared, to: item, manifestId: manifestId)
        return PersistedPreparedTextAudio(stored: item, updated: updated, prepared: prepared)
    }

    /// The save a finished assembly of chunks makes (#2256, #2509): one transaction that re-checks the preparation is still
    /// the item's, still live (no Stop, failure or new voice since the render began, #2134) and still for the text it
    /// was made from, then writes the audio. It reads and writes the store, so a caller runs it off the main thread and
    /// hands an `.attached` result to `SessionEngine.attachPreparedTextAudio(_:replaceActivePlayback:)` on it. Anything
    /// that moved on answers `.dropped` with nothing written, and the caller discards the audio without a failure.
    public func persistAssembly(
        itemId: String,
        prepared: PreparedTextAudio,
        manifest: PreparedAudioManifest,
        itemText: String?,
        sourceText: String
    ) throws -> PreparedAudioAssemblyAttach {
        let result = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: repository) { saved, current -> PersistedPreparedTextAudio? in
            guard PreparedAudioEnqueue.mayComplete(saved.state) else { return nil }
            guard current.text == itemText,
                  try PreparedAudioEnqueue.preparedText(item: current, repository: repository) == sourceText else { return nil }
            return try persist(itemId: itemId, prepared: prepared)
        }
        if let inner = result, let persisted = inner { return .attached(persisted) }
        return .dropped
    }

    /// Checks the source text is still what the audio was made from, then writes it (one transaction when the store has them).
    func write(_ prepared: PreparedTextAudio, to item: Item, manifestId: String? = nil) throws -> Item {
        let write = { () throws -> Item in
            if let manifestId, let manifest = try repository.loadPreparedAudioManifest(id: manifestId),
               !PreparedAudioEnqueue.mayComplete(manifest.state) {
                throw PreparedTextAudioRefusal.preparationRetired
            }
            let stored = try repository.loadItem(id: item.id)
            guard stored.deletedAt == nil, stored.text == item.text,
                  SessionEngine.preparedAudioMatches(prepared, item: stored) else {
                throw SessionKitError.invalidCommandForState("applyPreparedTextAudio:source_text_changed")
            }
            return try writePrepared(prepared, to: stored)
        }
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(write) }
        return try write()
    }

    private func writePrepared(_ prepared: PreparedTextAudio, to item: Item) throws -> Item {
        let transcriptId = item.transcriptId ?? "generated-transcript-\(item.id)"
        let map = currentMap?.itemId == item.id ? currentMap : (try? repository.loadListeningMap(itemId: item.id))
        let timeline = SessionEngine.generatedTextTimeline(prepared.timeline, using: map)
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: transcriptId,
            itemId: item.id,
            createdAt: prepared.createdAt,
            timeline: timeline
        ))
        var updated = item
        updated.text = prepared.normalizedText
        updated.media = prepared.media
        updated.transcriptId = transcriptId
        if updated.status == "ready" || updated.status == "needs_listening_map" {
            updated.status = currentMap == nil ? "needs_listening_map" : "ready"
        }
        try repository.saveItem(storedItem(updated, publisher: publisher))
        return updated
    }
}

// MARK: Source transcript timeline

typealias NormalizedTranscript = (text: String, timeline: TranscriptTimeline)

public struct PersistedTranscriptTimeline: Sendable {
    public let item: Item
}

public struct TranscriptTimelinePersister: Sendable {
    let repository: any SessionRepository
    let publisher: PublisherAudioPlayback?

    /// Keeps a publisher's chapters over the new timeline's, normalises the text, then saves the timeline and item.
    /// The reads and the heavy text step come first, outside any write. The item is then loaded again and both rows
    /// are saved in one transaction, so a trash, a completion mark or a title edit that landed while this ran off the
    /// main thread is kept, not overwritten by the item as it was when the work began.
    public func persist(itemId: String, timeline: TranscriptTimeline) throws -> PersistedTranscriptTimeline {
        let prepared = try normalize(itemId: itemId, timeline: timeline)
        let write = { () throws -> PersistedTranscriptTimeline in try commit(prepared, itemId: itemId) }
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(write) }
        return try write()
    }

    /// What the heavy step made, with what it was made from, so the write can tell whether that moved.
    struct PreparedTranscript {
        let timeline: TranscriptTimeline
        /// The publisher's chapters kept over the new timeline's, nil when none were.
        let keptChapters: [MediaTimelineChapter]?
        let normalized: NormalizedTranscript
    }

    /// The reads and the heavy text step. Writes nothing.
    func normalize(itemId: String, timeline: TranscriptTimeline) throws -> PreparedTranscript {
        try normalize(timeline, keeping: try publisherChapters(itemId: itemId))
    }

    private func normalize(_ timeline: TranscriptTimeline, keeping chapters: [MediaTimelineChapter]?) -> PreparedTranscript {
        var preferred = timeline
        if let chapters { preferred.chapters = chapters }
        return PreparedTranscript(timeline: timeline, keptChapters: chapters, normalized: SessionEngine.normalizedSourceTranscriptTimeline(preferred))
    }

    /// The chapters a publisher's map has put on the stored timeline, which a transcript must not replace.
    private func publisherChapters(itemId: String) throws -> [MediaTimelineChapter]? {
        guard let map = try repository.loadListeningMap(itemId: itemId),
              SessionEngine.publisherChapterSource(from: map.id) != nil,
              let existing = try repository.loadTranscriptTimeline(itemId: itemId)?.timeline.chapters,
              !existing.isEmpty else { return nil }
        return existing
    }

    /// Saves the timeline and the item as it is stored now. A publisher's chapters that landed since the heavy step are
    /// kept over this timeline's: the step runs again then, which is rare.
    func commit(_ prepared: PreparedTranscript, itemId: String) throws -> PersistedTranscriptTimeline {
        var item = try repository.loadItem(id: itemId)
        let chapters = try publisherChapters(itemId: itemId)
        let normalized = chapters == prepared.keptChapters ? prepared.normalized : normalize(prepared.timeline, keeping: chapters).normalized
        let transcriptId = item.transcriptId ?? "transcript-\(item.id)"
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: transcriptId,
            itemId: item.id,
            createdAt: Date(),
            timeline: normalized.timeline
        ))
        item.transcriptId = transcriptId
        item.text = normalized.text
        if item.status == "ready" || item.status == "needs_transcript" || item.status == "audio_ready" {
            item.status = "needs_listening_map"
        }
        try repository.saveItem(storedItem(item, publisher: publisher))
        return PersistedTranscriptTimeline(item: item)
    }
}

// MARK: Publisher chapters

public struct PersistedPublisherChapters: Sendable {
    public let item: Item
    public let map: ListeningMap
}

public struct PublisherChaptersPersister: Sendable {
    let repository: any SessionRepository
    let publisher: PublisherAudioPlayback?

    /// Returns nil when a higher-precedence map is already stored or no chapter survives normalising: nothing is written.
    public func persist(itemId: String, collection: PublisherChapterCollection) throws -> PersistedPublisherChapters? {
        var item = try repository.loadItem(id: itemId)
        if let existingMap = try repository.loadListeningMap(itemId: itemId),
           let existingSource = SessionEngine.publisherChapterSource(from: existingMap.id),
           existingSource.precedence > collection.source.precedence {
            return nil
        }

        let existingTimeline = try repository.loadTranscriptTimeline(itemId: itemId)
        let durationMs = item.media?.durationMs ?? existingTimeline?.timeline.durationMs
        let normalized = SessionEngine.normalizedPublisherChapters(collection.chapters, durationMs: durationMs)
        guard !normalized.isEmpty else { return nil }

        let segments = existingTimeline?.timeline.segments ?? []
        let mediaChapters = normalized.enumerated().map { index, chapter in
            let id = SessionEngine.publisherChapterId(source: collection.source, index: index)
            let segmentId = segments.last(where: { $0.startMs <= chapter.startMs })?.id
                ?? segments.first?.id
                ?? "publisher-anchor-\(index + 1)"
            return MediaTimelineChapter(
                id: id,
                title: chapter.title,
                description: chapter.description,
                startMs: chapter.startMs,
                transcriptSegmentId: segmentId
            )
        }
        let timeline = TranscriptTimeline(
            segments: segments,
            chapters: mediaChapters,
            durationMs: durationMs ?? normalized.compactMap(\.endMs).max() ?? normalized.last?.startMs
        )
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: existingTimeline?.id ?? "media-chapters-\(itemId)",
            itemId: itemId,
            createdAt: existingTimeline?.createdAt ?? Date(),
            timeline: timeline
        ))

        let percentDuration = max(1, timeline.durationMs ?? normalized.last?.startMs ?? 1)
        let chapters = normalized.enumerated().map { index, chapter in
            Chapter(
                id: mediaChapters[index].id,
                title: chapter.title,
                startChar: index,
                endChar: index + 1,
                percent: max(0, min(100, Int((Double(chapter.startMs) / Double(percentDuration) * 100).rounded())))
            )
        }
        let map = ListeningMap(
            id: "map-\(itemId)-publisher-\(collection.source.rawValue)",
            itemId: itemId,
            overview: ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count),
            chapters: chapters
        )
        try repository.saveListeningMap(map)
        // A community map never outlives the publisher's chapters (#553): the episode may have
        // asked for one while its audio, and so its embedded chapters, was not yet readable.
        try repository.removeCommunityMap(itemId: itemId)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try repository.saveItem(storedItem(item, publisher: publisher))
        }
        return PersistedPublisherChapters(item: item, map: map)
    }
}

// MARK: Generated Listening Map

/// What `ListeningMapGenerationPersister.generate` found or saved. `item` is nil when the item already had a map: that
/// map is handed back as it was, nothing is written, and the item is not loaded at all.
public struct GeneratedListeningMapResult: Sendable {
    public let item: Item?
    public let map: ListeningMap
    /// False when the map was already there.
    public let created: Bool
}

/// The store halves of `SessionEngine.generateListeningMap` (#2256), built like the persisters above. The Prepare
/// Listening Map tap used to load the item, cut its whole text into chapters and save the map on the main actor: 24 ms
/// on a 20 KB article, 787 ms on a 1.1 MB book. This does all three off it; `SessionEngine.generateListeningMap(_:)`
/// is the half that updates what the engine has open.
public struct ListeningMapGenerationPersister: Sendable {
    let repository: any SessionRepository
    let publisher: PublisherAudioPlayback?

    /// Makes the map the same way the engine always has, then saves it. The reads and the chapter cutting come first,
    /// outside any write. The item is then loaded again and the map and the status flip are written in one
    /// transaction, so a rename, a trash or a map that landed while this ran off the main thread is kept, not
    /// overwritten by the item as it was when the work began. A map that is there by then (a publisher's chapters, a
    /// friend's map) is returned unchanged, as it is when the item had one at the start.
    public func generate(itemId: String) throws -> GeneratedListeningMapResult {
        switch try prepare(itemId: itemId) {
        case .existing(let result): return result
        case .made(let prepared):
            let write = { () throws -> GeneratedListeningMapResult in try commit(prepared, itemId: itemId) }
            if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(write) }
            return try write()
        }
    }

    /// What the heavy step made, with the item text it was made from, so the write can tell whether that moved.
    struct PreparedMap {
        let map: ListeningMap
        let sourceText: String?
    }

    enum Preparation {
        case existing(GeneratedListeningMapResult)
        case made(PreparedMap)
    }

    /// The reads and the chapter cutting. Writes nothing.
    func prepare(itemId: String) throws -> Preparation {
        if let existing = try repository.loadListeningMap(itemId: itemId) {
            return .existing(GeneratedListeningMapResult(item: nil, map: existing, created: false))
        }
        let loaded = try repository.loadItem(id: itemId)
        let text = GeneratedListeningMap.text(for: loaded, transcript: transcript(itemId: itemId))
        return .made(PreparedMap(map: GeneratedListeningMap.make(for: loaded, text: text), sourceText: loaded.text))
    }

    /// Saves the map and flips the status of the item as it is stored now. Run inside one transaction.
    func commit(_ prepared: PreparedMap, itemId: String) throws -> GeneratedListeningMapResult {
        if let existing = try repository.loadListeningMap(itemId: itemId) {
            return GeneratedListeningMapResult(item: nil, map: existing, created: false)
        }
        var item = try repository.loadItem(id: itemId)
        // The text moved since the chapters were cut (rare): cut them again from what is stored now.
        let map = item.text == prepared.sourceText
            ? prepared.map
            : GeneratedListeningMap.make(for: item, text: GeneratedListeningMap.text(for: item, transcript: transcript(itemId: itemId)))
        try repository.saveListeningMap(map)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try repository.saveItem(storedItem(item, publisher: publisher))
        }
        return GeneratedListeningMapResult(item: item, map: map, created: true)
    }

    /// The source transcript the chapters fall back to for an item with no text: the publisher's, else the stored one.
    private func transcript(itemId: String) -> TranscriptTimeline? {
        if let publisher { return publisher.timeline }
        return try? repository.loadTranscriptTimeline(itemId: itemId)?.timeline
    }
}
