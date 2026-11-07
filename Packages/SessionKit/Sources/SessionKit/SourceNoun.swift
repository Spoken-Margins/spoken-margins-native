import Foundation

/// What a listener calls the thing they are listening to: "Episode", "Article" or "PDF" (#3597). Screens that talk about
/// the open source use this instead of the app's own word "item", which only the owner uses. It reads the same facts the
/// Library row reads (`LibraryRowWording.contentType`), so a row that says "Podcast" is an episode everywhere.
public struct SourceNoun: Equatable, Sendable {
    /// For the start of a sentence: "Episode paused while it plays."
    public let capitalized: String
    /// For the middle of one: "when the episode gets there". A PDF stays "PDF".
    public let inSentence: String

    public init(capitalized: String, inSentence: String) {
        self.capitalized = capitalized
        self.inSentence = inSentence
    }

    public static let episode = SourceNoun(capitalized: "Episode", inSentence: "episode")
    public static let article = SourceNoun(capitalized: "Article", inSentence: "article")
    public static let pdf = SourceNoun(capitalized: "PDF", inSentence: "PDF")
    public static let book = SourceNoun(capitalized: "Book", inSentence: "book")
    public static let audiobook = SourceNoun(capitalized: "Audiobook", inSentence: "audiobook")
    /// Pasted or imported text with no better name.
    public static let text = SourceNoun(capitalized: "Text", inSentence: "text")

    public init(contentType: LibraryContentTypeFilter) {
        switch contentType {
        case .podcast: self = .episode
        case .article: self = .article
        case .pdf: self = .pdf
        case .epub: self = .book
        case .audiobook: self = .audiobook
        case .text, .all: self = .text
        }
    }

    /// From the open source's own stored facts (the same three the Library row reads).
    public init(mediaType: String, sourceReference: String?, sourceReferenceType: String?) {
        self.init(contentType: LibraryRowWording.contentType(
            mediaType: mediaType, sourceReference: sourceReference, sourceReferenceType: sourceReferenceType))
    }
}
