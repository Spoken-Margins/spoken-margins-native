import Foundation

/// An item's Margins laid out under its chapters or scenes, in source order (E2, #778).
///
/// The one presenter behind the item's notebook page, meant to feed the per-item note (#587)
/// and Share as Markdown (#493) too, so what the app shows and what lands in the notes folder
/// have the same headings in the same order. Pure: no storage.
///
/// Headings are the publisher's chapters; without them, the listening map's scenes with their
/// one-line summaries; without either, a heading every 10 minutes ("0–10 min") for media or
/// every 10 paragraphs for text. Under each, the listener's own and shared Margins are
/// interleaved by position. A recap Margin made at the end (#142) goes under "At the end", and
/// a Margin with no place yet under "Not placed yet".
public struct ItemNotebook: Equatable, Sendable {
    public static let spanMs = 10 * 60_000
    public static let spanParagraphs = 10
    /// A media Margin this close to the end counts as made at the end.
    public static let endToleranceMs = 1_000

    public enum Unit: Equatable, Sendable {
        /// Positions in milliseconds: podcasts and other media.
        case media
        /// Positions in characters: articles, PDFs and other spoken text.
        case text

        var skimUnit: SkimStops.PositionUnit {
            switch self {
            case .media: .milliseconds
            case .text: .characters(perSecond: 0)
            }
        }
    }

    /// A chapter or scene to lay Margins under, in the item's unit.
    public struct Heading: Equatable, Sendable {
        public var id: String
        public var title: String
        public var summary: String?
        public var start: Int

        public init(id: String, title: String, summary: String? = nil, start: Int) {
            self.id = id
            self.title = title
            self.summary = summary
            self.start = max(0, start)
        }

        /// A publisher chapter of a podcast.
        public init(_ chapter: MediaTimelineChapter) {
            self.init(id: chapter.id, title: chapter.title, start: chapter.startMs)
        }

        /// A chapter of a text item, or a text listening-map scene with its summary. Positions are
        /// characters, so only for `unit: .text`.
        public init(_ chapter: Chapter, summary: String? = nil) {
            self.init(id: chapter.id, title: chapter.title, summary: summary, start: chapter.startChar)
        }

        /// A podcast's listening-map scene. Positions are milliseconds, so only for `unit: .media`.
        public init(_ scene: EpisodeSceneDraft, title: String? = nil, summary: String? = nil) {
            self.init(id: scene.id, title: title ?? scene.publisherTitle ?? "Scene \(scene.order + 1)", summary: summary, start: scene.startMs)
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public enum Origin: Equatable, Sendable {
            case own
            /// A friend's Margin; the name is the packet's label, when it has one.
            case shared(senderName: String?)
        }

        public var marginID: String
        public var origin: Origin
        /// In the item's unit. Nil under "Not placed yet".
        public var position: Int?
        /// A shared podcast Margin placed by the sender's time or an estimate, not a verified match.
        public var isApproximate: Bool
        public var createdAt: Date

        public var id: String { marginID }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case chapter
            case scene
            /// A 10-minute or 10-paragraph stretch of an item with no chapters or scenes.
            case span
            case atTheEnd
            case notPlacedYet
        }

        public var id: String
        public var kind: Kind
        public var title: String
        public var summary: String?
        /// Where the section starts, in the item's unit. Nil for the last two kinds.
        public var start: Int?
        public var entries: [Entry]
    }

    public var sections: [Section]

    /// Builds the notebook.
    /// - Parameters:
    ///   - chapters: the publisher's chapters, for media or text.
    ///   - scenes: the listening map's scenes, used when there are no chapters.
    ///   - paragraphStarts: for text with neither, where each paragraph starts.
    ///   - end: the item's length in its unit (duration, or text length). Margins at it are recaps.
    ///   - senderNames: shared Margins' sender names by layer id (`ImportedCommentaryLayer.displayLabel`).
    public static func build(
        unit: Unit,
        chapters: [Heading] = [],
        scenes: [Heading] = [],
        paragraphStarts: [Int] = [],
        end: Int? = nil,
        ownMargins: [Interjection],
        sharedMargins: [ImportedCommentaryInterjection] = [],
        senderNames: [String: String] = [:]
    ) -> ItemNotebook {
        var placed: [Entry] = []
        var atEnd: [Entry] = []
        var unplaced: [Entry] = []

        func isAtEnd(_ position: Int, roughPercent: Int?) -> Bool {
            if let roughPercent, roughPercent >= 100 { return true }
            guard let end, end > 0 else { return false }
            return position >= end - (unit == .media ? endToleranceMs : 0)
        }
        func file(_ entry: Entry, roughPercent: Int?) {
            guard let position = entry.position else { return unplaced.append(entry) }
            if isAtEnd(position, roughPercent: roughPercent) { atEnd.append(entry) } else { placed.append(entry) }
        }

        // Only Margins on the item itself: one on an AI reply is anchored in that reply's text.
        for margin in ownMargins where margin.targetType == .item {
            let stop = SkimStop.margin(margin, unit: unit.skimUnit)
            file(Entry(marginID: margin.id, origin: .own, position: stop?.position, isApproximate: false, createdAt: margin.createdAt),
                 roughPercent: margin.roughPercent)
        }
        for margin in sharedMargins {
            let stop = SkimStop.margin(margin, unit: unit.skimUnit)
            let approximate = unit == .media && (SharedMarginPlaybackPosition(margin)?.isApproximate ?? false)
            file(Entry(marginID: margin.id, origin: .shared(senderName: senderNames[margin.layerId]), position: stop?.position,
                       isApproximate: approximate, createdAt: margin.createdAt),
                 roughPercent: margin.anchorEvidence.roughPercent)
        }

        var sections: [Section] = []
        if !chapters.isEmpty || !scenes.isEmpty {
            let kind: Section.Kind = chapters.isEmpty ? .scene : .chapter
            let headings = (chapters.isEmpty ? scenes : chapters).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            sections = headings.map { Section(id: "\(kind)-\($0.id)", kind: kind, title: $0.title, summary: $0.summary, start: $0.start, entries: []) }
            for entry in placed {
                // Under the last heading at or before it; a Margin before the first heading goes under the first.
                let index = sections.lastIndex { ($0.start ?? 0) <= (entry.position ?? 0) } ?? 0
                sections[index].entries.append(entry)
            }
        } else {
            sections = spans(unit: unit, paragraphStarts: paragraphStarts, holding: placed)
        }

        if !atEnd.isEmpty {
            sections.append(Section(id: "at-the-end", kind: .atTheEnd, title: "At the end", start: nil, entries: atEnd))
        }
        if !unplaced.isEmpty {
            sections.append(Section(id: "not-placed-yet", kind: .notPlacedYet, title: "Not placed yet", start: nil, entries: unplaced))
        }
        for index in sections.indices { sections[index].entries.sort(by: inSourceOrder) }
        return ItemNotebook(sections: sections)
    }

    /// The 10-minute or 10-paragraph stretches that hold Margins, so a long item without
    /// structure doesn't fill the page with empty headings.
    private static func spans(unit: Unit, paragraphStarts: [Int], holding entries: [Entry]) -> [Section] {
        var byIndex: [Int: [Entry]] = [:]
        let starts = paragraphStarts.sorted()
        for entry in entries {
            let position = entry.position ?? 0
            let index: Int
            switch unit {
            case .media:
                index = position / spanMs
            case .text:
                let paragraph = starts.lastIndex { $0 <= position } ?? 0
                index = paragraph / spanParagraphs
            }
            byIndex[index, default: []].append(entry)
        }
        return byIndex.keys.sorted().map { index in
            switch unit {
            case .media:
                let minutes = spanMs / 60_000
                return Section(id: "span-\(index)", kind: .span, title: "\(index * minutes)–\((index + 1) * minutes) min",
                               start: index * spanMs, entries: byIndex[index] ?? [])
            case .text:
                let first = index * spanParagraphs
                let last = min(starts.count, first + spanParagraphs)
                let title = starts.isEmpty ? "The text" : first + 1 == last ? "Paragraph \(last)" : "Paragraphs \(first + 1)–\(last)"
                return Section(id: "span-\(index)", kind: .span, title: title,
                               start: starts.indices.contains(first) ? starts[first] : 0, entries: byIndex[index] ?? [])
            }
        }
    }

    private static func inSourceOrder(_ a: Entry, _ b: Entry) -> Bool {
        let (pa, pb) = (a.position ?? .max, b.position ?? .max)
        if pa != pb { return pa < pb }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.marginID < b.marginID
    }
}

extension ItemNotebook {
    /// Sender names by layer id, from the item's imported layers.
    public static func senderNames(from layers: [ImportedCommentaryLayer]) -> [String: String] {
        var names: [String: String] = [:]
        for layer in layers {
            if let label = layer.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                names[layer.id] = label
            }
        }
        return names
    }
}
