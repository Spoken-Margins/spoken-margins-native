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
    /// Chapter indices in reading order, and each one's start clamped into the text. Worked out once: a long
    /// transcript has many chapters, and counting its Characters for each of them on every redraw is slow.
    private let order: [Int]
    private let starts: [Int]
    /// What the reader shows now.
    public private(set) var current: PlaybackTextReaderTarget

    public init(text: String, chapters: [Chapter], opening: PlaybackTextReaderTarget) {
        self.text = text
        self.chapters = chapters
        self.opening = opening
        self.current = opening
        let length = text.count
        self.order = PlaybackTextReaderTarget.readingOrder(chapters)
        self.starts = chapters.map { PlaybackTextReaderTarget.clamp($0.startChar, length) }
    }

    public var isAtOpening: Bool { current == opening }

    /// The shown chapter's place among the chapters that start at different points, for "2 of 7"; nil with no chapters.
    public var position: (number: Int, count: Int)? {
        guard let index = current.chapterIndex, chapters.indices.contains(index) else { return nil }
        let distinct = distinctStarts
        guard let number = distinct.firstIndex(of: starts[index]) else { return nil }
        return (number + 1, distinct.count)
    }

    public func canStep(_ direction: Direction) -> Bool { neighbour(direction) != nil }

    /// Shows the neighbouring chapter; does nothing at either end of the item.
    public mutating func step(_ direction: Direction) {
        guard let index = neighbour(direction) else { return }
        // Chapters that share a start show the same text, so reaching the opening's start is the opening.
        current = openingStart == starts[index]
            ? opening
            : PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, chapterIndex: index)
    }

    public mutating func returnToOpening() { current = opening }

    private var openingStart: Int? {
        opening.chapterIndex.flatMap { starts.indices.contains($0) ? starts[$0] : nil }
    }

    private var distinctStarts: [Int] {
        var seen = Set<Int>()
        return order.map { starts[$0] }.filter { seen.insert($0).inserted }
    }

    private func neighbour(_ direction: Direction) -> Int? {
        guard let index = current.chapterIndex, chapters.indices.contains(index) else { return nil }
        let here = starts[index]
        let target: Int?
        switch direction {
        case .next: target = order.map { starts[$0] }.first(where: { $0 > here })
        case .previous: target = order.map { starts[$0] }.last(where: { $0 < here })
        }
        // Of chapters sharing that start, the last in reading order is the one `resolve` picks.
        return target.flatMap { start in order.last(where: { starts[$0] == start }) }
    }
}
