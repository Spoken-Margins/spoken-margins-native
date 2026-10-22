import Foundation

/// Rules for an article whose pre-rendered narration can't be played (#237).
///
/// Once an article's narration is rendered to a file, its session plays that file as
/// `transcriptBackedMedia`. The file can later disappear (storage eviction, iOS purging a cache) or
/// fail to decode. The article's text is still there, so the listener should hear it read with
/// on-device speech from the same place, and the item should stop pointing at the file so it can be
/// rendered again. `SessionEngine` applies these rules; the playback coordinator (A2 M2) absorbs them.
public enum PreparedNarrationFallback {
    /// The file URL a generated-narration target plays, or nil when the target is anything else.
    public static func fileURL(forTargetId targetId: String) -> URL? {
        guard let url = URL(string: targetId), url.isFileURL else { return nil }
        return url
    }

    /// True when `media` names a generated-narration file that isn't on disk.
    public static func isMissing(_ media: ItemMedia?, fileManager: FileManager = .default) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered,
              let url = fileURL(forTargetId: identifier(of: media)) else { return false }
        return !fileManager.fileExists(atPath: url.path)
    }

    /// True when `session` plays `item`'s generated narration and `item` has text to read instead.
    /// An item whose media was already cleared still qualifies: its session can outlive the media.
    ///
    /// `playingPublisherAudio`: the session plays the article's publisher recording (#547), which an
    /// article's text can always stand in for, whatever the item stores.
    public static func canReadText(instead session: Session, item: Item, playingPublisherAudio: Bool = false) -> Bool {
        guard session.currentTargetType == .transcriptBackedMedia,
              session.itemId == item.id,
              !isAudioFirst(item),
              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        if playingPublisherAudio { return true }
        switch item.media?.sourceType {
        case .some(.generatedTTSPrerendered):
            return true
        case .none, .some(.generatedTTSRealtime):
            return fileURL(forTargetId: session.currentTargetId) != nil
        case .some(.nativeMediaFile), .some(.remoteStream), .some(.browserOwnedMedia):
            return false
        }
    }

    /// True when `media` names the file `targetId` plays. A session can outlive the render it was
    /// playing: after the article is prepared again, the item names a newer render (#277).
    public static func media(_ media: ItemMedia?, isTarget targetId: String) -> Bool {
        guard let target = fileURL(forTargetId: targetId) else { return false }
        return [media?.url, media?.nativeMediaId].contains { value in
            guard let value, let url = URL(string: value), url.isFileURL else { return false }
            return url.standardizedFileURL.path == target.standardizedFileURL.path
        }
    }

    /// `session` moved to live speech of the item's text at the place its saved media time reached.
    /// The caller sets the chapter, which depends on the listening map.
    public static func liveSpeechSession(
        from session: Session,
        item: Item,
        timeline: TranscriptTimeline?
    ) -> Session {
        let textLength = item.text?.count ?? 0
        var offset = session.position.charOffset
        if let mediaTimeMs = session.position.mediaTimeMs, let timeline, !timeline.segments.isEmpty {
            offset = textOffset(mediaTimeMs: mediaTimeMs, timeline: timeline)
        }
        // Both the timeline and a media session's saved character offset are interpolated inside a segment by
        // time share, which lands mid-word; on-device speech starting there would say "entence..." (#2128).
        offset = wordStart(atOrBefore: offset, in: item.text ?? "")
        offset = max(0, min(offset, textLength))
        var updated = session
        updated.currentTargetType = .itemTextTTS
        updated.currentTargetId = item.id
        updated.position = Position(charOffset: offset)
        if textLength > 0 {
            updated.completionPercent = min(100, max(0, Int((Double(offset) / Double(textLength)) * 100)))
        }
        return updated
    }

    /// The longest word `wordStart` will back up through. A longer run without whitespace (a pasted URL or
    /// data) has no word start worth the re-reading, so its offset stays where it is.
    private static let longestWordBackedUpThrough = 64

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    private static func isWrittenWithoutSpaces(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || (0x3040...0x30FF).contains(scalar.value) || (0x0E00...0x0EFF).contains(scalar.value)
        }
    }

    /// `offset` moved back to the start of the word it falls inside, so speech begins on a whole word.
    /// An offset already at a word start, on whitespace, at the end or past it is returned as it is. A word
    /// is a run of non-whitespace characters, offsets count characters (as `String.count` does), and
    /// punctuation stays with its word. A sentence-ending mark also ends the word before it (`end.Next`), and
    /// a script written without spaces (Chinese, Japanese, Thai) has no words to snap to, so it is left as it is.
    public static func wordStart(atOrBefore offset: Int, in text: String) -> Int {
        guard offset > 0, offset < text.count else { return offset }
        var index = text.index(text.startIndex, offsetBy: offset)
        guard !text[index].isWhitespace, !isWrittenWithoutSpaces(text[index]) else { return offset }
        var start = offset
        while start > 0 {
            let previous = text.index(before: index)
            if text[previous].isWhitespace || sentenceEnders.contains(text[previous]) { return start }
            guard offset - start < longestWordBackedUpThrough else { return offset }
            index = previous
            start -= 1
        }
        return 0
    }

    /// The text offset generated narration has reached at `mediaTimeMs`, interpolated within a segment.
    public static func textOffset(mediaTimeMs: Int, timeline: TranscriptTimeline) -> Int {
        let sortedSegments = timeline.segments.sorted { $0.startMs < $1.startMs }
        guard !sortedSegments.isEmpty else { return 0 }
        let clamped = max(0, mediaTimeMs)
        let segment = sortedSegments.first { $0.startMs <= clamped && clamped < $0.endMs }
            ?? sortedSegments.last(where: { $0.startMs <= clamped })
            ?? sortedSegments.first
        guard let segment,
              let startChar = segment.startChar,
              let endChar = segment.endChar,
              segment.endMs > segment.startMs,
              endChar > startChar else {
            return segment?.startChar ?? 0
        }
        let fraction = Double(clamped - segment.startMs) / Double(segment.endMs - segment.startMs)
        let offset = startChar + Int((Double(endChar - startChar) * max(0, min(1, fraction))).rounded())
        return max(startChar, min(offset, endChar))
    }

    /// Where a Margin is heard in an article's generated narration (#1537). A Margin recorded while the narration
    /// played keeps its own media time. One recorded while the article was read with on-device speech (before it
    /// was prepared, or while a render was still on its way) has only a text place, which the narration timeline
    /// finds. Nil when the render doesn't reach that place: the caller reads it with on-device speech instead.
    public static func mediaTimeMs(forMargin anchor: Anchor, timeline: TranscriptTimeline?) -> Int? {
        if let mediaTimeMs = anchor.mediaTimeMs { return mediaTimeMs }
        guard let timeline else { return nil }
        return mediaTimeMs(textOffset: anchor.startChar, timeline: timeline)
    }

    /// The media time generated narration reaches `textOffset`, interpolated within a segment. Text between two
    /// segments maps to the next segment's start. Nil when the rendered audio has no text positions or ends
    /// before `textOffset` (a partly rendered article), so a caller never seeks to a place the audio can't reach.
    public static func mediaTimeMs(textOffset: Int, timeline: TranscriptTimeline) -> Int? {
        let sortedSegments = timeline.segments.sorted { $0.startMs < $1.startMs }
        guard sortedSegments.contains(where: { $0.startChar != nil && $0.endChar != nil }) else { return nil }
        if let segment = sortedSegments.first(where: { segment in
            guard let start = segment.startChar, let end = segment.endChar else { return false }
            return start <= textOffset && textOffset < end
        }) {
            guard let startChar = segment.startChar,
                  let endChar = segment.endChar,
                  endChar > startChar else {
                return segment.startMs
            }
            let fraction = Double(textOffset - startChar) / Double(endChar - startChar)
            return segment.startMs + Int((Double(segment.endMs - segment.startMs) * max(0, min(1, fraction))).rounded())
        }
        return sortedSegments.first(where: { ($0.startChar ?? .max) > textOffset })?.startMs
    }

    /// Once an item's narration is detached, its "ready offline" prepared audio must be prepared
    /// again, or Prepare answers "already available offline" while the item plays live speech (#278).
    public static func markPreparedAudioForRepreparation(
        itemId: String, repository: any PreparedAudioRepository, now: Date = Date()
    ) throws {
        for var manifest in try repository.loadPreparedAudioManifests(itemId: itemId) where manifest.state == .readyOffline {
            manifest.state = .needsRepreparation
            manifest.failureCode = "narration_detached"
            manifest.updatedAt = now
            try repository.savePreparedAudioManifest(manifest)
        }
    }

    /// What deleting a stored file does to the items that play it.
    public enum FileRelease: Equatable, Sendable {
        /// No item plays the file.
        case unreferenced
        /// These items play the file as generated narration. Save them (media cleared) before
        /// deleting it; they read their text live until the narration is rendered again.
        case detach([Item])
        /// An item plays the file as its only audio. Don't delete it.
        case keep
    }

    /// Decides whether `fileURL` can be deleted to free space without leaving an item pointing at a
    /// missing file.
    public static func release(_ fileURL: URL, from items: [Item]) -> FileRelease {
        FileReferences(items: items).release(fileURL)
    }

    /// Which items play which stored files, indexed once for an eviction pass.
    public struct FileReferences: Sendable {
        private var itemsByFile: [String: [Item]] = [:]

        public init(items: [Item]) {
            for item in items {
                let keys = Set([item.media?.url, item.media?.nativeMediaId].compactMap { value -> String? in
                    guard let value, let url = URL(string: value), url.isFileURL else { return nil }
                    return storageKey(url)
                })
                for key in keys { itemsByFile[key, default: []].append(item) }
            }
        }

        public func release(_ fileURL: URL) -> FileRelease {
            let referencing = itemsByFile[storageKey(fileURL)] ?? []
            guard !referencing.isEmpty else { return .unreferenced }
            guard referencing.allSatisfy({ $0.media?.sourceType == .generatedTTSPrerendered }) else { return .keep }
            return .detach(referencing.map { item in
                var detached = item
                detached.media = nil
                return detached
            })
        }

        /// Records that `fileURL` was deleted after its items were detached.
        public mutating func forget(_ fileURL: URL) {
            itemsByFile[storageKey(fileURL)] = nil
        }
    }

    /// iOS can move the app's data container during an update, so an item saved before then names
    /// the file under an older container path. Compare the part below Application Support.
    private static func storageKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let marker = path.range(of: "/Library/Application Support/") else { return path }
        return String(path[marker.upperBound...])
    }

    /// True for an item whose audio is the source itself, so reading its text isn't a substitute.
    static func isAudioFirst(_ item: Item) -> Bool { audioFirstMediaTypes.contains(item.mediaType) }

    /// Items whose audio is the source itself, so reading their text isn't a substitute.
    private static let audioFirstMediaTypes: Set<String> = [
        TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue, "audiobook", "guided_tour"
    ]

    private static func identifier(of media: ItemMedia?) -> String {
        [media?.url, media?.nativeMediaId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}
