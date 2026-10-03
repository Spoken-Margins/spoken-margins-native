import Foundation

public struct SourceLocator: Codable, Equatable, Hashable, Sendable {
    public var documentId: String
    public var spineItemId: String?
    public var segmentId: String
    public var utf8Start: Int
    public var utf8End: Int

    public init(
        documentId: String,
        spineItemId: String? = nil,
        segmentId: String,
        utf8Start: Int,
        utf8End: Int
    ) {
        self.documentId = documentId
        self.spineItemId = spineItemId
        self.segmentId = segmentId
        self.utf8Start = max(0, utf8Start)
        self.utf8End = max(self.utf8Start, utf8End)
    }
}

public struct CanonicalNavigationNode: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var locator: SourceLocator?
    public var children: [CanonicalNavigationNode]

    public init(id: String, title: String, locator: SourceLocator? = nil, children: [CanonicalNavigationNode] = []) {
        self.id = id
        self.title = title
        self.locator = locator
        self.children = children
    }
}

public struct SpeakableSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var locator: SourceLocator

    public init(id: String, text: String, locator: SourceLocator) {
        self.id = id
        self.text = text
        self.locator = locator
    }
}

public enum CanonicalSourceFormat: String, Codable, Equatable, Sendable {
    case plainText = "plain_text"
    case markdown
    case pdf
    case epub
    case article
}

public struct CanonicalSourcePackage: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var sourceDocumentId: String
    public var format: CanonicalSourceFormat
    public var title: String
    public var author: String?
    public var language: String?
    public var navigation: [CanonicalNavigationNode]
    public var segments: [SpeakableSegment]
    public var createdAt: Date

    public init(
        schemaVersion: String = "canonical-source.v1",
        id: String,
        itemId: String,
        sourceDocumentId: String,
        format: CanonicalSourceFormat,
        title: String,
        author: String? = nil,
        language: String? = nil,
        navigation: [CanonicalNavigationNode],
        segments: [SpeakableSegment],
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.itemId = itemId
        self.sourceDocumentId = sourceDocumentId
        self.format = format
        self.title = title
        self.author = author
        self.language = language
        self.navigation = navigation
        self.segments = segments
        self.createdAt = createdAt
    }

    /// Projects authored navigation into the legacy character-offset map used by
    /// the current item and playback surfaces. The canonical package remains the
    /// source of truth; this map is a derived navigation index.
    public func derivedListeningMap() -> ListeningMap? {
        let flattened = navigation.flatMap(Self.flattenedNavigation)
            .compactMap { node -> (node: CanonicalNavigationNode, start: Int)? in
                guard let locator = node.locator else { return nil }
                return (node, LegacySourceOffsetAdapter.characterOffset(for: locator, in: segmentsText))
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.node.id < $1.node.id
            }

        var unique: [(node: CanonicalNavigationNode, start: Int)] = []
        for entry in flattened where unique.last?.start != entry.start {
            unique.append(entry)
        }
        guard !unique.isEmpty else { return nil }

        let textLength = segmentsText.count
        let chapters = unique.enumerated().map { index, entry in
            let end = index + 1 < unique.count ? unique[index + 1].start : textLength
            let percent = textLength > 0
                ? Int((Double(entry.start) / Double(textLength) * 100).rounded())
                : 0
            return Chapter(
                id: entry.node.id,
                title: entry.node.title,
                startChar: entry.start,
                endChar: max(entry.start, end),
                percent: max(0, min(100, percent))
            )
        }
        return ListeningMap(
            id: "canonical-navigation-\(itemId)",
            itemId: itemId,
            overview: ListeningMapOverviewText.appGenerated(title: title, chapterCount: chapters.count),
            chapters: chapters
        )
    }

    private var segmentsText: String {
        segments.map(\.text).joined(separator: "\n\n")
    }

    private static func flattenedNavigation(_ node: CanonicalNavigationNode) -> [CanonicalNavigationNode] {
        node.children.isEmpty ? [node] : node.children.flatMap(flattenedNavigation)
    }
}

public enum LegacySourceOffsetAdapter {
    public static func characterOffset(for locator: SourceLocator, in text: String) -> Int {
        let clamped = min(max(0, locator.utf8Start), text.utf8.count)
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
        guard let index = String.Index(utf8Index, within: text) else {
            return text[..<text.index(text.startIndex, offsetBy: min(text.count, clamped))].count
        }
        return text.distance(from: text.startIndex, to: index)
    }

    public static func locator(
        documentId: String,
        spineItemId: String? = nil,
        segmentId: String,
        characterRange: Range<Int>,
        in text: String
    ) -> SourceLocator {
        let lower = text.index(text.startIndex, offsetBy: min(max(0, characterRange.lowerBound), text.count))
        let upper = text.index(text.startIndex, offsetBy: min(max(characterRange.lowerBound, characterRange.upperBound), text.count))
        return SourceLocator(
            documentId: documentId,
            spineItemId: spineItemId,
            segmentId: segmentId,
            utf8Start: text[..<lower].utf8.count,
            utf8End: text[..<upper].utf8.count
        )
    }
}
