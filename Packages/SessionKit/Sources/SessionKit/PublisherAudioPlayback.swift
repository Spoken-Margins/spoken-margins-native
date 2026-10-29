import Foundation

/// How an article plays its publisher's own recording (#547, slice 3 of #239).
///
/// An article with a `publisher_audio` record that holds a text-to-time map plays the recording as
/// `transcriptBackedMedia` through that map, so a Margin recorded at time t lands on the article's
/// words and the recording and the text stay in step. The article itself never changes in the
/// Library: `SessionEngine` plays a copy of the item whose `media` is the recording, and what it
/// saves is the article, with the session in article form (`itemTextTTS` at the text offset the map
/// gives for the playing time). Build 29 therefore opens the database, sees a plain article, and
/// resumes it with on-device speech from the same place.
///
/// If the recording can't play, `PreparedNarrationFallback` reads the text from the mapped place.
public struct PublisherAudioPlayback: Equatable, Sendable {
    public let recording: PublisherAudio
    /// The recording's map: article sentences with their times in the recording.
    public let timeline: TranscriptTimeline
    /// What the item plays while the recording does.
    public let playingMedia: ItemMedia
    /// What the item itself stores, restored when the playing copy is saved.
    public let storedMedia: ItemMedia?

    /// The recording `item` plays instead of on-device speech, or nil when it plays as it always did:
    /// the record needs a usable map and a web address, and the item must be an article with text
    /// whose own audio (if any) is generated narration, never a recording the listener owns. A summary answers as the
    /// whole item does, so a caller that only asks whether the recording plays need not decode the article (#2508).
    public static func plan(for item: some LibraryItemFields, record: PublisherAudio?) -> PublisherAudioPlayback? {
        guard let record, record.itemId == item.id,
              let timeline = record.textMap,
              timeline.segments.contains(where: { $0.startChar != nil && $0.endChar != nil }),
              let url = URL(string: record.audioURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              item.deletedAt == nil,
              !PreparedNarrationFallback.isAudioFirst(item),
              item.hasListenableText else { return nil }
        switch item.media?.sourceType {
        case .none, .some(.generatedTTSRealtime), .some(.generatedTTSPrerendered):
            break
        case .some(.nativeMediaFile), .some(.remoteStream), .some(.browserOwnedMedia):
            return nil
        }
        return PublisherAudioPlayback(
            recording: record,
            timeline: timeline,
            playingMedia: ItemMedia(
                sourceType: .remoteStream, url: record.audioURL,
                durationMs: record.durationMs ?? timeline.durationMs
            ),
            storedMedia: item.media
        )
    }

    /// The same plan with `timeline` as the map the engine plays through. The engine adds the article's
    /// Listening Map chapters, as it does for generated narration, so chapter jumps find their time.
    public func with(timeline: TranscriptTimeline) -> PublisherAudioPlayback {
        PublisherAudioPlayback(recording: recording, timeline: timeline, playingMedia: playingMedia, storedMedia: storedMedia)
    }

    /// `item` as the engine plays it: its audio is the recording.
    public func playing(_ item: Item) -> Item {
        guard item.media != playingMedia else { return item }
        var playing = item
        playing.media = playingMedia
        return playing
    }

    /// `item` as the Library stores it: the recording is not part of the article.
    public func stored(_ item: Item) -> Item {
        guard item.media == playingMedia else { return item }
        var stored = item
        stored.media = storedMedia
        return stored
    }

    /// True when `targetId` is this recording.
    public func plays(targetId: String) -> Bool { targetId == recording.audioURL }

    /// The session as the Library stores it: reading the article at the text offset the recording
    /// has reached. Anything else (a Margin being recorded, an answer playing) is stored as it is.
    public func stored(_ session: Session, item: Item) -> Session {
        guard session.currentTargetType == .transcriptBackedMedia, plays(targetId: session.currentTargetId) else {
            return session
        }
        var stored = session
        let textLength = item.text?.count ?? 0
        var offset = session.position.charOffset
        if let mediaTimeMs = session.position.mediaTimeMs {
            offset = PreparedNarrationFallback.textOffset(mediaTimeMs: mediaTimeMs, timeline: timeline)
        }
        stored.currentTargetType = .itemTextTTS
        stored.currentTargetId = session.itemId
        stored.position = Position(charOffset: max(0, min(offset, textLength)), chapterId: nil)
        return stored
    }

    /// The recording time for article text at `textOffset`. Generated narration maps text between two
    /// segments to the next segment's start, which is right for whitespace and headings. A publisher map
    /// may leave whole sentences out, and the recording still speaks them between the neighbours, so
    /// a place between two placed segments is the earlier one's end: the listener hears the sentence
    /// the place is in. Nil past the last placed segment, where the article keeps its on-device voice.
    public func mediaTimeMs(textOffset: Int) -> Int? {
        let placed = timeline.segments
            .filter { $0.startChar != nil && $0.endChar != nil }
            .sorted { $0.startMs < $1.startMs }
        let insideOne = placed.contains { ($0.startChar ?? .max) <= textOffset && textOffset < ($0.endChar ?? .min) }
        if !insideOne,
           let previous = placed.last(where: { ($0.endChar ?? .max) <= textOffset }),
           placed.contains(where: { ($0.startChar ?? .min) > textOffset }) {
            return previous.endMs
        }
        return PreparedNarrationFallback.mediaTimeMs(textOffset: textOffset, timeline: timeline)
    }

    /// A stored article session as it plays when the recording does: at the time the map gives for
    /// its text offset. Nil when the recording doesn't reach that place (a partly mapped article
    /// read past the end of what the recording covers), so the article keeps its on-device voice.
    public func playingSession(from stored: Session) -> Session? {
        guard stored.currentTargetType == .itemTextTTS,
              stored.phase == .itemPlayback,
              let mediaTimeMs = mediaTimeMs(textOffset: stored.position.charOffset) else {
            return nil
        }
        var playing = stored
        playing.currentTargetType = .transcriptBackedMedia
        playing.currentTargetId = recording.audioURL
        playing.position = Position(charOffset: stored.position.charOffset, mediaTimeMs: mediaTimeMs, chapterId: nil)
        return playing
    }
}
