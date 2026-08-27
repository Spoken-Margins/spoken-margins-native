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
