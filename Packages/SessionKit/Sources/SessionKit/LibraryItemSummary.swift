import Foundation

/// The fields of an item that the Library rows and audio preparation read. `Item` has them, and so does
/// `LibraryItemSummary`, which has them without the document text (#2102).
public protocol LibraryItemFields {
    var id: String { get }
    var title: String { get }
    var mediaType: String { get }
    var status: String { get }
    var externalReference: String? { get }
    var externalReferenceType: String? { get }
    var media: ItemMedia? { get }
    var deletedAt: Date? { get }
    var author: String? { get }
    var sourceTitle: String? { get }
    var sourceURL: String? { get }
    var createdAt: Date? { get }
    var sourceCompletedAt: Date? { get }
    /// Whether the item has text with something in it besides whitespace.
    var hasListenableText: Bool { get }
    /// How many characters the listening-time estimate counts. nil when the item has no text.
    var textCharacterCount: Int? { get }
}

extension Item: LibraryItemFields {
    public var hasListenableText: Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public var textCharacterCount: Int? {
        ListeningTimeEstimator.characterCount(of: text)
    }
}

/// A repository that can find the items made from one web address without reading the rest of the Library. A re-import
/// uses it, so finding "have I imported this before" does not parse every document's text.
public protocol ItemAddressLookup {
    func listItems(withExternalReference address: String) throws -> [Item]
}

/// An item as the Library list needs it: every field of `Item` the rows read, and no `text` or `documentStructure`.
/// Those two are most of an article's or book's bytes, and decoding them for every item made each tap that rebuilds the
/// Library wait for the whole store (#2102). It is a type of its own, not an `Item` with the text left out, so a
/// summary can never be saved back over the real item.
public struct LibraryItemSummary: LibraryItemFields, Equatable, Sendable {
    public var id: String
    public var title: String
    public var mediaType: String
    public var status: String
    public var externalReference: String?
    public var externalReferenceType: String?
    public var media: ItemMedia?
    public var deletedAt: Date?
    public var author: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var createdAt: Date?
    public var sourceCompletedAt: Date?
    public var hasListenableText: Bool
    public var textCharacterCount: Int?

    public init(
        id: String,
        title: String,
        mediaType: String,
        status: String,
        externalReference: String? = nil,
        externalReferenceType: String? = nil,
        media: ItemMedia? = nil,
        deletedAt: Date? = nil,
        author: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        createdAt: Date? = nil,
        sourceCompletedAt: Date? = nil,
        hasListenableText: Bool,
        textCharacterCount: Int?
    ) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.status = status
        self.externalReference = externalReference
        self.externalReferenceType = externalReferenceType
        self.media = media
        self.deletedAt = deletedAt
        self.author = author
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.sourceCompletedAt = sourceCompletedAt
        self.hasListenableText = hasListenableText
        self.textCharacterCount = textCharacterCount
    }

    /// The summary of a whole item. A summary read from the store answers the same.
    public init(_ item: Item) {
        self.init(
            id: item.id, title: item.title, mediaType: item.mediaType, status: item.status,
            externalReference: item.externalReference, externalReferenceType: item.externalReferenceType,
            media: item.media, deletedAt: item.deletedAt, author: item.author, sourceTitle: item.sourceTitle,
            sourceURL: item.sourceURL, createdAt: item.createdAt, sourceCompletedAt: item.sourceCompletedAt,
            hasListenableText: item.hasListenableText, textCharacterCount: item.textCharacterCount)
    }
}
