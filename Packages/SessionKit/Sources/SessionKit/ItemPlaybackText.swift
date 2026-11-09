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

    /// Reads what a play of `itemId` will speak and projects it for the voice, so the play itself finds the projection
    /// ready. Runs on the calling thread: call it off the main actor. Nothing is written, and an item with no text, a
    /// item that plays a recording or a short text does nothing.
    public static func prewarmProjection(
        itemId: String,
        repository: SessionRepository,
        forSystemSpeech: Bool
    ) {
        guard let item = try? repository.loadItem(id: itemId),
              item.mediaType != TargetType.transcriptBackedMedia.rawValue,
              item.mediaType != TargetType.browserOwnedMedia.rawValue,
              item.media?.url == nil, // a recording plays, not the text
              item.text?.isEmpty == false else { return }
        let map = try? repository.loadListeningMap(itemId: itemId)
        var listenable: NormalizedSpeechText?
        if item.mediaType == "pdf" {
            let document = try? (repository as? StructuredDocumentRepository)?.loadStructuredDocument(itemId: itemId)
            listenable = StructuredDocumentSpeech.listenableProjection(item: item, document: document)
        }
        SpeechTextNormalizer.prewarm(text(item: item, map: map, listenable: listenable), forSystemSpeech: forSystemSpeech)
    }
}
