import Foundation

/// The text a play of an item's own text speaks: the Listening Map's spoken preface, then the item's text (a PDF's
/// listenable text on the new reader). `SessionEngine` speaks exactly this, and the app projects exactly this ahead of
/// a play (#2256), so the two cannot drift: a projection made for a different text would be wasted.
public enum ItemPlaybackText {
    public static func preface(item: Item, map: ListeningMap?, listenable: NormalizedSpeechText?) -> String {
        guard let map else { return "" }
        let title = item.title
        return ListeningMapOverviewText.spokenPreface(
            overview: map.overview,
            title: title,
            chapterCount: map.chapters.count,
            textOpening: String((listenable?.text ?? item.text ?? "").prefix(title.count * 2 + 200))
        )
    }

    public static func text(item: Item, map: ListeningMap?, listenable: NormalizedSpeechText?) -> String {
        preface(item: item, map: map, listenable: listenable) + (listenable?.text ?? item.text ?? "")
    }

    /// Reads what a play of `itemId` will speak and projects it for the voices in `kinds`, so the play itself finds the projection
    /// ready. Runs on the calling thread: call it off the main actor. Nothing is written, and an item with no text, a
    /// item that plays a recording or a short text does nothing.
    ///
    /// A PDF's listenable text is built here too (its document read and its projection), and returned so the engine can
    /// keep it: `SessionEngine.adoptPrewarmedListenableProjection` takes it, so a play does not read the document and
    /// build the text again on the main thread (#2256). Every other item returns nil.
    @discardableResult
    public static func prewarmProjection(
        itemId: String,
        repository: SessionRepository,
        kinds: SpeechTextNormalizer.PrewarmVoiceKinds
    ) -> PrewarmedListenableProjection? {
        guard let item = try? repository.loadItem(id: itemId),
              item.mediaType != TargetType.transcriptBackedMedia.rawValue,
              item.mediaType != TargetType.browserOwnedMedia.rawValue,
              item.media?.url == nil, // a recording plays, not the text
              let itemText = item.text, !itemText.isEmpty else { return nil }
        let map = try? repository.loadListeningMap(itemId: itemId)
        var listenable: NormalizedSpeechText?
        var prewarmed: PrewarmedListenableProjection?
        if item.mediaType == "pdf" {
            let document = try? (repository as? StructuredDocumentRepository)?.loadStructuredDocument(itemId: itemId)
            listenable = StructuredDocumentSpeech.listenableProjection(item: item, document: document)
            prewarmed = PrewarmedListenableProjection(itemId: itemId, textLength: itemText.count, projection: listenable)
        }
        SpeechTextNormalizer.prewarm(text(item: item, map: map, listenable: listenable), kinds: kinds)
        return prewarmed
    }
}

/// A PDF's listenable projection (`StructuredDocumentSpeech.listenableProjection`) built off the main thread, for the
/// engine to keep. `projection` is nil for a PDF with no usable document, which the engine also remembers: it is the
/// answer a play would have worked out. It is matched to the item's text by length, as the engine's own cache is, and
/// the engine accepts it only if no document was saved since the generation the caller read before building it.
public struct PrewarmedListenableProjection: Sendable, Equatable {
    public let itemId: String
    public let textLength: Int
    public let projection: NormalizedSpeechText?

    public init(itemId: String, textLength: Int, projection: NormalizedSpeechText?) {
        self.itemId = itemId
        self.textLength = textLength
        self.projection = projection
    }
}
