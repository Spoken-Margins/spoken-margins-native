import Foundation

/// Read-only inputs for playback chapter labels and timeline selection.
public struct PlaybackChapterContext {
    public var snapshot: SessionSnapshot
    public var id: String
    public var title: String
    public var chapters: [Chapter]
    public var mediaChapters: [MediaTimelineChapter]
    public var listeningMapScenes: [MediaTimelineChapter]
    public var turns: [ConversationTurn]
    public var sessionItemId: String?
    public var sessionChapterId: String?

    public init(
        snapshot: SessionSnapshot,
        id: String,
        title: String,
        chapters: [Chapter],
        mediaChapters: [MediaTimelineChapter],
        listeningMapScenes: [MediaTimelineChapter],
        turns: [ConversationTurn],
        sessionItemId: String?,
        sessionChapterId: String?
    ) {
        self.snapshot = snapshot
        self.id = id
        self.title = title
        self.chapters = chapters
        self.mediaChapters = mediaChapters
        self.listeningMapScenes = listeningMapScenes
        self.turns = turns
        self.sessionItemId = sessionItemId
        self.sessionChapterId = sessionChapterId
    }
}

public enum PlaybackChapterLocator {
    public static func playbackHeaderTitle(_ context: PlaybackChapterContext) -> String {
        let snapshot = context.snapshot
        let selectedItem = context
        let itemTitle = selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedTitle = (snapshot.chapterTitle ?? snapshot.title ?? itemTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotTitle = reportedTitle.isEmpty || reportedTitle.caseInsensitiveCompare(itemTitle) == .orderedSame
            ? (inferredPlaybackChapterTitle(context) ?? itemTitle)
            : reportedTitle
        guard !snapshotTitle.isEmpty else { return itemTitle }
        guard snapshotTitle.caseInsensitiveCompare(itemTitle) != .orderedSame else { return itemTitle }

        let chapterTitles = playbackChapterTitles(context)
        guard let chapterIndex = chapterTitles.firstIndex(where: {
            $0.caseInsensitiveCompare(snapshotTitle) == .orderedSame
        }) else {
            return snapshotTitle
        }
        return ChapterHeaderLabel.title(snapshotTitle, index: chapterIndex)
    }

    private static func inferredPlaybackChapterTitle(_ context: PlaybackChapterContext) -> String? {
        let snapshot = context.snapshot
        let selectedItem = context
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return currentChapter(context)?.title
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            let mediaTimeMs = snapshot.currentMediaTimeMs ?? 0
            let authoredChapters = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
            if let title = authoredChapters.last(where: { $0.startMs <= mediaTimeMs })?.title {
                return title
            }
            return selectedItem.listeningMapScenes
                .sorted { $0.startMs < $1.startMs }
                .last(where: { $0.startMs <= mediaTimeMs })?
                .title
        default:
            return nil
        }
    }

    public static func isCurrentTimelineChapter(_ chapter: Chapter, turnId: String? = nil, context: PlaybackChapterContext) -> Bool {
        let snapshot = context.snapshot
        let selectedItem = context
        if turnId == nil {
            let sourceTargetTypes = [
                TargetType.itemTextTTS.rawValue,
                TargetType.transcriptBackedMedia.rawValue,
                TargetType.browserOwnedMedia.rawValue
            ]
            guard let targetType = snapshot.targetType, sourceTargetTypes.contains(targetType) else { return false }
            if let currentChapterId = context.sessionChapterId,
               selectedItem.chapters.contains(where: { $0.id == currentChapterId }) {
                return currentChapterId == chapter.id
            }
            if let currentTitle = snapshot.chapterTitle,
               selectedItem.chapters.contains(where: { $0.title.caseInsensitiveCompare(currentTitle) == .orderedSame }) {
                return currentTitle.caseInsensitiveCompare(chapter.title) == .orderedSame
            }
            return currentChapter(context)?.id == chapter.id
        }

        let expectedTargetType = selectedItem.turns.first(where: { $0.id == turnId })?.turnType == "interjection_summary"
            ? TargetType.summaryTurnTTS.rawValue
            : TargetType.assistantTurnTTS.rawValue
        guard snapshot.targetType == expectedTargetType else { return false }
        if let turnId, snapshot.targetId != turnId { return false }
        if let currentChapterId = context.sessionChapterId {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    public static func isCurrentTimelineMediaChapter(_ chapter: MediaTimelineChapter, context: PlaybackChapterContext) -> Bool {
        let snapshot = context.snapshot
        let selectedItem = context
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue else {
            return false
        }
        if let currentChapterId = context.sessionChapterId,
           selectedItem.mediaChapters.contains(where: { $0.id == currentChapterId }) {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    public static func isCurrentTimelineListeningMapScene(_ scene: MediaTimelineChapter, context: PlaybackChapterContext) -> Bool {
        let snapshot = context.snapshot
        let selectedItem = context
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let currentTimeMs = snapshot.currentMediaTimeMs else {
            return false
        }
        let scenes = selectedItem.listeningMapScenes.sorted { $0.startMs < $1.startMs }
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return false }
        let endMs = scenes.indices.contains(index + 1) ? scenes[index + 1].startMs : Int.max
        return currentTimeMs >= scene.startMs && currentTimeMs < endMs
    }

    private static func playbackChapterTitles(_ context: PlaybackChapterContext) -> [String] {
        let snapshot = context.snapshot
        let selectedItem = context
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return selectedItem.chapters.map(\.title)
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return selectedItem.turns
                .first(where: { $0.id == snapshot.targetId })?
                .chapters?
                .map(\.title) ?? []
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            let authoredTitles = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
            if !authoredTitles.isEmpty { return authoredTitles }
            return selectedItem.listeningMapScenes
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
        default:
            return []
        }
    }

    public static func currentChapter(_ context: PlaybackChapterContext) -> Chapter? {
        let snapshot = context.snapshot
        let selectedItem = context
        // Multiple short chapters can share one rounded percentage. Prefer
        // the exact source position so the label cannot jump ahead of audio.
        if snapshot.targetType == TargetType.itemTextTTS.rawValue,
           let offset = snapshot.currentTextStart {
            return selectedItem.chapters.last { $0.startChar <= offset } ?? selectedItem.chapters.first
        }
        if let sessionItemId = context.sessionItemId, sessionItemId == selectedItem.id,
           let chapter = selectedItem.chapters.first(where: { $0.id == context.sessionChapterId }) {
            return chapter
        }
        if let title = snapshot.chapterTitle,
           let chapter = selectedItem.chapters.first(where: { $0.title == title }) {
            return chapter
        }
        return selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
    }
}
