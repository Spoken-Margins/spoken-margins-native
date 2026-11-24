import Foundation

extension PlaybackLivePassage {
    public struct Fragment: Identifiable, Equatable, Sendable {
        public let id: String
        public let start: Int
        public let text: String
        public let role: StructuredDocument.Role
        public let label: String?
        public let pageIndex: Int?
    }

    /// Retained Timeline metadata, indexed once instead of counting all source text on every tick.
    public struct SourceIndex: Sendable {
        private struct Span: Sendable {
            let entry: TimelineSourceContent.Entry
            let end: Int
        }
        private let spans: [Span]
        /// How footnote markers show (#5109). A fragment's text is shown text; its `start` stays a stored-text offset.
        private let footnotes: FootnoteDisplayText

        /// - Parameter footnotes: the item's markers as shown, from `FootnoteDisplayText(text:)` of the same text.
        public init(_ source: TimelineSourceContent, footnotes: FootnoteDisplayText = .none) {
            self.footnotes = footnotes
            let values = source.entries.map { Span(entry: $0, end: $0.start + $0.text.count) }
            // I13 segments must not overlap. Fall back to the exact source sentence for malformed metadata.
            var previousEnd = 0
            let valid = values.allSatisfy { span in
                defer { previousEnd = span.end }
                return span.entry.start >= previousEnd && span.end <= source.characterCount
            }
            spans = valid ? values : []
        }

        /// Exact partition of a displayed sentence, including gaps omitted by Timeline's paragraph rows.
        public func fragments(for sentence: Sentence) -> [Fragment] {
            let characters = Array(sentence.text)
            guard !characters.isEmpty else { return [] }
            var lower = 0
            var upper = spans.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if spans[middle].end <= sentence.start { lower = middle + 1 } else { upper = middle }
            }
            var index = lower
            var cursor = sentence.start
            let limit = sentence.start + characters.count
            var result: [Fragment] = []
            while cursor < limit {
                while index < spans.count && spans[index].end <= cursor { index += 1 }
                let span = index < spans.count ? spans[index] : nil
                let owner = span.flatMap { $0.entry.start <= cursor ? $0 : nil }
                let end = min(limit, owner?.end ?? span?.entry.start ?? limit)
                guard end > cursor else { break }
                result.append(Fragment(id: "\(cursor)::\(owner?.entry.id ?? "source.gap")", start: cursor,
                                       text: footnotes.render(String(characters[(cursor - sentence.start)..<(end - sentence.start)]),
                                                              from: cursor),
                                       role: owner?.entry.role ?? .body, label: owner?.entry.label,
                                       pageIndex: owner?.entry.pageIndex))
                cursor = end
            }
            return result
        }
    }
}
