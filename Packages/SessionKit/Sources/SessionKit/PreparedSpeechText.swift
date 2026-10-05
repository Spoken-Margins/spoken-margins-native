import Foundation

/// The text an item's prepared (pre-rendered) audio is planned, identified and committed
/// against (#336). It must be exactly what the player speaks after any preface: for a PDF on
/// the new reader (extraction v2) that is the I14 listenable text, without references, tables
/// or running heads; for every other item it is `Item.text`.
public struct PreparedSpeechText: Equatable, Sendable {
    /// What prepared audio is planned, identified and committed against.
    public let text: String
    /// `Item.text`, which positions, Margins and assembled narration stay in.
    public let itemText: String
    /// Each character of `text` at its offset in `Item.text`; nil when `text` is `Item.text`.
    public let listenable: NormalizedSpeechText?

    public init?(item: Item, document: StructuredDocument?) {
        guard let itemText = item.text else { return nil }
        self.itemText = itemText
        listenable = StructuredDocumentSpeech.listenableProjection(item: item, document: document)
        text = listenable?.text ?? itemText
    }

    /// Spoken offsets (in `SpeechTextNormalizer.normalize(text)`, where prepared chunks start)
    /// to `Item.text` offsets, so assembled narration's timeline stays in `Item.text`.
    public func assemblyProjection() -> NormalizedSpeechText {
        let spoken = SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        guard let listenable else { return spoken }
        return NormalizedSpeechText(
            text: spoken.text,
            sourceOffsets: spoken.sourceOffsets.map { listenable.sourceOffset(atSpokenCharacterOffset: $0) },
            sourceLength: itemText.count
        )
    }
}

/// Resolves `PreparedSpeechText` for the player's per-chunk lookups without rebuilding a
/// paper's listenable text for every chunk. An entry is reused only for the same `Item.text`.
public final class PreparedSpeechTextCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PreparedSpeechText] = [:]

    public init() {}

    public func resolve(item: Item, documents: StructuredDocumentRepository?) -> PreparedSpeechText? {
        guard let text = item.text else { return nil }
        // Only a PDF can have a listenable text; everything else is its own text.
        guard item.mediaType == "pdf" else { return PreparedSpeechText(item: item, document: nil) }
        lock.lock()
        let cached = entries[item.id]
        lock.unlock()
        if let cached, cached.itemText == text { return cached }
        let document = try? documents?.loadStructuredDocument(itemId: item.id)
        guard let resolved = PreparedSpeechText(item: item, document: document) else { return nil }
        // A PDF without a document yet isn't remembered, so one saved later is found.
        guard resolved.listenable != nil else { return resolved }
        lock.lock()
        if entries.count >= 8 { entries.removeAll() }
        entries[item.id] = resolved
        lock.unlock()
        return resolved
    }
}
