import Foundation

/// What the playback bar draws for one source: its length, where its chapters start and where its Margins sit (#428).
///
/// A podcast bar is measured in seconds and a text bar in characters, the units of the scrubber's own range, so the
/// view can feed the scrubber's value straight to `PlaybackBarLayout`. Margins sit where the Timeline lists them.
public struct PlaybackBarContent: Sendable, Equatable {
    public let length: Double
    public let chapterStarts: [Double]
    public let marks: [PlaybackBarLayout.Mark]

    public init(length: Double, chapterStarts: [Double], marks: [PlaybackBarLayout.Mark]) {
        self.length = length
        self.chapterStarts = chapterStarts
        self.marks = marks
    }

    /// Where a podcast's chapters start, by the rule the rest of the app uses: the media chapters when there are any,
    /// else the generated Listening Map's scenes. Chapters that only mirror the transcript's own segments are left out,
    /// as in the Timeline, and a chapter that is also a source chapter still counts: it is on the bar either way.
    public static func chapterStartsMs(mediaChapters: [MediaTimelineChapter], scenes: [MediaTimelineChapter]) -> [Int] {
        let real = mediaChapters.filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
        return (real.isEmpty ? scenes : real).map(\.startMs).sorted()
    }

    /// A podcast bar. `chapterStartsMs` are the chapters the Timeline lists. Nil when the duration isn't known yet.
    public static func media(
        durationMs: Int,
        chapterStartsMs: [Int],
        own: [Interjection],
        shared: [ImportedCommentaryInterjection]
    ) -> PlaybackBarContent? {
        guard durationMs > 0 else { return nil }
        let seconds = Double(durationMs) / 1_000
        return PlaybackBarContent(
            length: seconds,
            chapterStarts: chapterStartsMs.map { Double($0) / 1_000 },
            marks: own.compactMap { PlaybackBarLayout.Mark.media($0, durationSeconds: seconds) }
                + shared.compactMap { PlaybackBarLayout.Mark.media($0, durationSeconds: seconds) }
        )
    }

    /// A text bar. Nil for a source with no text.
    public static func text(
        length: Int,
        chapterStartChars: [Int],
        own: [Interjection],
        shared: [ImportedCommentaryInterjection]
    ) -> PlaybackBarContent? {
        guard length > 0 else { return nil }
        return PlaybackBarContent(
            length: Double(length),
            chapterStarts: chapterStartChars.map(Double.init),
            marks: own.compactMap { PlaybackBarLayout.Mark.text($0) }
                + shared.compactMap { PlaybackBarLayout.Mark.text($0, textLength: length) }
        )
    }
}
