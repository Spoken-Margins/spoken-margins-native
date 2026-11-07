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

public struct PreparedTextAudioPersister: Sendable {
    let repository: any SessionRepository
    let profile: RuntimeCapabilityProfile
    let currentMap: ListeningMap?
    let publisher: PublisherAudioPlayback?

    /// Loads the item, lets the guard decide, then writes the prepared audio's timeline and item.
    public func persist(itemId: String, prepared: PreparedTextAudio) throws -> PersistedPreparedTextAudio {
        let item = try repository.loadItem(id: itemId)
        guard SessionEngine.shouldPrepareGeneratedTextAudio(for: item, profile: profile) else {
            return PersistedPreparedTextAudio(stored: item, updated: nil, prepared: prepared)
        }
        let updated = try write(prepared, to: item)
        return PersistedPreparedTextAudio(stored: item, updated: updated, prepared: prepared)
    }

    /// Checks the source text is still what the audio was made from, then writes it (one transaction when the store has them).
    func write(_ prepared: PreparedTextAudio, to item: Item) throws -> Item {
        let write = { () throws -> Item in
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

public struct PersistedTranscriptTimeline: Sendable {
    public let item: Item
}

public struct TranscriptTimelinePersister: Sendable {
    let repository: any SessionRepository
    let publisher: PublisherAudioPlayback?

    /// Keeps a publisher's chapters over the new timeline's, normalises the text, then saves the timeline and item.
    public func persist(itemId: String, timeline: TranscriptTimeline) throws -> PersistedTranscriptTimeline {
        var item = try repository.loadItem(id: itemId)
        var timelineWithPreferredChapters = timeline
        if let map = try repository.loadListeningMap(itemId: itemId),
           SessionEngine.publisherChapterSource(from: map.id) != nil,
           let existingChapters = try repository.loadTranscriptTimeline(itemId: itemId)?.timeline.chapters,
           !existingChapters.isEmpty {
            timelineWithPreferredChapters.chapters = existingChapters
        }
        let normalized = SessionEngine.normalizedSourceTranscriptTimeline(timelineWithPreferredChapters)
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
