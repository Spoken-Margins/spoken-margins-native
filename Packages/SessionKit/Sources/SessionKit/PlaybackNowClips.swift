import Foundation

/// A table's or figure's card among the Now tab's sentences, and where following scrolls while one is read (#4588).
extension PlaybackLivePassage {
    /// One row of the whole scene: a sentence, or the card of a table or figure standing between sentences.
    public enum SceneItem: Identifiable, Equatable, Sendable {
        case sentence(Sentence)
        /// `id` is negative (the card's place in the anchor list, from -1), so it never equals a sentence's id, which is
        /// a Character offset of 0 or more.
        case clip(floatId: String, id: Int)

        public var id: Int {
            switch self {
            case .sentence(let sentence): sentence.id
            case .clip(_, let id): id
            }
        }

        public var sentence: Sentence? {
            if case .sentence(let sentence) = self { sentence } else { nil }
        }
    }

    /// Which cards a scene shows and between which sentences.
    public enum ClipPlacement {
        public struct Result: Equatable, Sendable {
            public let items: [SceneItem]
            /// For each card's id, the start of the sentence it stands before. A card after the last sentence has the
            /// scene's end here, which no lit sentence reaches.
            public let holdStarts: [Int: Int]
            /// The card ids, in the order they stand.
            public var clipIds: [Int] { items.compactMap { if case .clip(_, let id) = $0 { id } else { nil } } }
        }

        /// The scene's rows with a card before the sentence that holds each anchor.
        /// - `anchors` are in the order `PDFClipAnchors.make` returns them; a card's id is `-(its index + 1)`.
        /// - `saved` holds the float ids that have a picture file: an anchor not in it gives no card.
        /// - An anchor outside the scene's character range gives no card. One before the first sentence's start stands
        ///   before the first; one in the space between two sentences stands before the later; one past the last
        ///   sentence stands after it.
        public static func items(scene: Scene, anchors: [PDFClipAnchor], saved: Set<String>) -> Result {
            let sentences = scene.sentences
            guard !sentences.isEmpty else { return Result(items: [], holdStarts: [:]) }
            var before: [Int: [(id: Int, floatId: String)]] = [:]
            var holdStarts: [Int: Int] = [:]
            for (position, anchor) in anchors.enumerated() where saved.contains(anchor.floatId) {
                guard anchor.anchor >= scene.chapterStart, anchor.anchor < scene.chapterEnd else { continue }
                let index = firstSentence(endingAfter: anchor.anchor, in: sentences)
                let id = -(position + 1)
                before[index, default: []].append((id, anchor.floatId))
                holdStarts[id] = index < sentences.count ? sentences[index].start : sentences[sentences.count - 1].end
            }
            var items: [SceneItem] = []
            items.reserveCapacity(sentences.count + holdStarts.count)
            for (index, sentence) in sentences.enumerated() {
                for clip in before[index] ?? [] { items.append(.clip(floatId: clip.floatId, id: clip.id)) }
                items.append(.sentence(sentence))
            }
            for clip in before[sentences.count] ?? [] { items.append(.clip(floatId: clip.floatId, id: clip.id)) }
            return Result(items: items, holdStarts: holdStarts)
        }

        /// The index of the first sentence that ends after `offset`; `sentences.count` when there is none.
        private static func firstSentence(endingAfter offset: Int, in sentences: [Sentence]) -> Int {
            var lower = 0
            var upper = sentences.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sentences[middle].end <= offset { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
    }

    /// How big a card is, from its picture's aspect and the room there is, without reading the picture (#4588). The
    /// frame is known before the file is read, so nothing jumps when the picture arrives.
    public enum ClipCardLayout {
        /// Room to the left of a card: the diamond gutter (18) and the spacing after it (10), so a card starts where the
        /// sentence highlight starts.
        public static let leadingInset = 28.0
        public static let minimumHeight = 44.0
        /// The Timeline row's cap (`TimelineClipPresentation.rowMaximumHeight`).
        public static let maximumHeight = 220.0
        /// A card is never taller than this share of the visible text area.
        public static let visibleShare = 0.45

        /// The card's width: the list's, less the leading inset. Never negative.
        public static func width(listWidth: Double) -> Double { max(0, listWidth - leadingInset) }

        /// The tallest a card may be in a text area `visibleHeight` points tall. Never below the minimum, so a card is
        /// always a target a finger can hit.
        public static func tallest(visibleHeight: Double) -> Double {
            max(minimumHeight, min(maximumHeight, visibleHeight * visibleShare))
        }

        /// The card's height for a picture of this aspect (width over height) at this width: the width divided by the
        /// aspect, held between the minimum and `tallest`. A picture with no usable aspect gets the minimum.
        public static func height(width: Double, aspect: Double, visibleHeight: Double) -> Double {
            let ceiling = tallest(visibleHeight: visibleHeight)
            guard width > 0, aspect.isFinite, aspect > 0 else { return minimumHeight }
            return min(ceiling, max(minimumHeight, width / aspect))
        }
    }

    /// Where following scrolls: to the lit sentence, as it always has, or to a card whose caption is being read.
    public enum ScrollTarget: Equatable, Sendable {
        case sentence
        case clip(id: Int)
    }

    /// The caption hold: while the sentences read since a card still fit under it, following keeps the card at the top
    /// of the text area, with its caption directly under it. Past that, following goes back to its usual line.
    public enum ClipHold {
        /// Heights and space the estimate uses, in points.
        public struct Metrics: Equatable, Sendable {
            public var columnWidth: Double
            public var visibleHeight: Double
            public var bodyPointSize: Double
            public var lineHeight: Double

            public init(columnWidth: Double, visibleHeight: Double, bodyPointSize: Double, lineHeight: Double) {
                self.columnWidth = columnWidth
                self.visibleHeight = visibleHeight
                self.bodyPointSize = bodyPointSize
                self.lineHeight = lineHeight
            }
        }

        public static let rowPadding = 20.0
        public static let minimumRowHeight = 44.0
        public static let rowSpacing = 10.0
        /// The space between the fragments of one sentence row (`NowSceneRow`'s stack).
        public static let fragmentSpacing = 4.0
        /// Room kept under the lit sentence inside the hold.
        public static let holdMargin = 12.0

        /// A sentence row's height, estimated without laying it out, with the space under it. Each line break in a
        /// fragment starts a line of its own; a table's fragments are monospaced, so they hold fewer characters per
        /// line; a fragment's label takes one more line.
        public static func rowHeight(fragments: [Fragment], metrics: Metrics) -> Double {
            guard metrics.columnWidth > 0, metrics.bodyPointSize > 0, metrics.lineHeight > 0 else { return .infinity }
            var lines = 0
            for fragment in fragments {
                let width = metrics.bodyPointSize * (fragment.role == .table ? 0.6 : 0.5)
                let perLine = max(1, Int((metrics.columnWidth / width).rounded(.down)))
                for line in fragment.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines += max(1, (line.count + perLine - 1) / perLine)
                }
                if fragment.label != nil { lines += 1 }
            }
            // A sentence row stacks its fragments with `fragmentSpacing` between them.
            let gaps = Double(max(0, fragments.count - 1)) * fragmentSpacing
            return max(minimumRowHeight, Double(lines) * metrics.lineHeight + rowPadding + gaps) + rowSpacing
        }

        /// Where to scroll for the sentence at index `lit` of `scene`.
        /// - `clips`: each card's id, the start of the sentence it stands before and its height with the space after it.
        /// - `sentenceHeight`: a sentence row's height by its index in the scene (`rowHeight`).
        /// - A card holds while the lit sentence is at or after the sentence it stands before and the rows from there
        ///   through the lit sentence, the cards among them and the held card, fit the visible height. Of several holding
        ///   cards the later one wins.
        /// - `dropped`: cards whose hold left the lit sentence off screen (`stillDropped`). They never hold again, so a
        ///   wrong estimate costs one correction, not one per sentence.
        public static func target(
            scene: Scene, lit: Int, clips: [(id: Int, holdStart: Int, height: Double)],
            visibleHeight: Double, dropped: Set<Int> = [], sentenceHeight: (Int) -> Double
        ) -> ScrollTarget {
            guard scene.sentences.indices.contains(lit), visibleHeight > 0 else { return .sentence }
            let litStart = scene.sentences[lit].start
            var best: (id: Int, holdStart: Int, order: Int)?
            for (order, clip) in clips.enumerated() where clip.holdStart <= litStart && !dropped.contains(clip.id) {
                let first = sentenceIndex(startingAt: clip.holdStart, in: scene.sentences)
                guard let first, first <= lit else { continue }
                var used = clip.height + holdMargin
                var tooTall = false
                for index in first...lit {
                    used += sentenceHeight(index)
                    if used > visibleHeight { tooTall = true; break }
                }
                guard !tooTall else { continue }
                // Cards that stand among the rows read since: later cards before the same sentence, and cards before
                // any later sentence up to the lit one.
                for (otherOrder, other) in clips.enumerated() where otherOrder != order && other.holdStart <= litStart
                    && (other.holdStart > clip.holdStart || (other.holdStart == clip.holdStart && otherOrder > order)) {
                    used += other.height
                }
                guard used <= visibleHeight else { continue }
                if best == nil || clip.holdStart > best!.holdStart || (clip.holdStart == best!.holdStart && order > best!.order) {
                    best = (clip.id, clip.holdStart, order)
                }
            }
            return best.map { .clip(id: $0.id) } ?? .sentence
        }

        /// Which dropped cards stay dropped when the lit sentence is at `litStart`: those it has not gone back before. A
        /// listener who rewinds to before a card, or a scene or card list that is rebuilt, gives the card its hold again.
        public static func stillDropped(_ dropped: Set<Int>, holdStarts: [Int: Int], litStart: Int) -> Set<Int> {
            dropped.filter { id in holdStarts[id].map { $0 <= litStart } ?? false }
        }

        private static func sentenceIndex(startingAt start: Int, in sentences: [Sentence]) -> Int? {
            var lower = 0
            var upper = sentences.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sentences[middle].start < start { lower = middle + 1 } else { upper = middle }
            }
            return lower < sentences.count && sentences[lower].start == start ? lower : nil
        }
    }
}
