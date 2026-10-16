import Foundation

/// Moving between chapters inside the source-text reader (#1579), without touching playback.
///
/// The reader opens at the playing chapter with the sentence being read lit (`PlaybackTextReaderTarget`, #1547).
/// Stepping shows the neighbouring chapter in reading order, from its top, and stepping back to the opening
/// chapter (or `returnToOpening`) shows the opening target again, sentence and all. Chapters that share a start
/// show once, as `PlaybackTextReaderTarget.resolve` shows them, so a step never lands on the same text.
public struct PlaybackTextReaderBrowser: Sendable, Equatable {
    public enum Direction: Sendable { case previous, next }

    private let text: String
    private let chapters: [Chapter]
    private let opening: PlaybackTextReaderTarget
    /// What the reader shows now.
    public private(set) var current: PlaybackTextReaderTarget

    public init(text: String, chapters: [Chapter], opening: PlaybackTextReaderTarget) {
        self.text = text
        self.chapters = chapters
        self.opening = opening
        self.current = opening
    }

    public var isAtOpening: Bool { current == opening }

    /// The shown chapter's place among the chapters that start at different points, for "2 of 7"; nil with no chapters.
    public var position: (number: Int, count: Int)? {
        guard let index = current.chapterIndex, chapters.indices.contains(index) else { return nil }
        let starts = distinctStarts
        guard let number = starts.firstIndex(of: clampedStart(index)) else { return nil }
        return (number + 1, starts.count)
    }

    public func canStep(_ direction: Direction) -> Bool { neighbour(direction) != nil }

    /// Shows the neighbouring chapter; does nothing at either end of the item.
    public mutating func step(_ direction: Direction) {
        guard let index = neighbour(direction) else { return }
        current = index == opening.chapterIndex
            ? opening
            : PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, chapterIndex: index)
    }

    public mutating func returnToOpening() { current = opening }

    private var length: Int { text.count }

    private func clampedStart(_ index: Int) -> Int { PlaybackTextReaderTarget.clamp(chapters[index].startChar, length) }

    private var distinctStarts: [Int] {
        var seen = Set<Int>()
        return PlaybackTextReaderTarget.readingOrder(chapters).map(clampedStart).filter { seen.insert($0).inserted }
    }

    private func neighbour(_ direction: Direction) -> Int? {
        guard let index = current.chapterIndex, chapters.indices.contains(index) else { return nil }
        let here = clampedStart(index)
        let order = PlaybackTextReaderTarget.readingOrder(chapters)
        let target: Int?
        switch direction {
        case .next: target = order.map(clampedStart).first(where: { $0 > here })
        case .previous: target = order.map(clampedStart).last(where: { $0 < here })
        }
        // Of chapters sharing that start, the last in reading order is the one `resolve` picks.
        return target.flatMap { start in order.last(where: { clampedStart($0) == start }) }
    }
}
