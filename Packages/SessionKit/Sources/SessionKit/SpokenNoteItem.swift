import Foundation

/// How a spoken note (#1609) sits in the Library: as an ordinary `Item`, with no new database shape (#3108).
///
/// The item's `mediaType` is the free-text string `spoken_note`, like `guided_tour`, so the previous build reads
/// the row as it reads any text item and shows the note's transcript as its text. The takes themselves stay in
/// `SpokenNoteStore`'s JSON beside the audio; the item's reference, `note://<noteId>`, says which note that is.
public enum SpokenNoteItem {
    public static let mediaType = "spoken_note"
    public static let referenceType = "spoken_note"
    public static let referencePrefix = "note://"
    public static let defaultTitle = "Spoken note"

    /// Whether a stored media type names a spoken note. Case does not matter, as with the other media types.
    public static func isSpokenNote(mediaType: String) -> Bool {
        mediaType.lowercased() == Self.mediaType
    }

    /// The item id for a note. The same note always gets the same item, so adding it twice can't make two rows.
    public static func itemId(forNoteId noteId: String) -> String {
        "spoken-note-\(noteId)"
    }

    public static func reference(forNoteId noteId: String) -> String {
        referencePrefix + noteId
    }

    /// The note id an item's reference names, or nil when it isn't a note reference or the id is empty.
    public static func noteId(fromReference reference: String?) -> String? {
        guard let reference, reference.hasPrefix(referencePrefix) else { return nil }
        let id = String(reference.dropFirst(referencePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// The note id behind an item, or nil when the item isn't a spoken note.
    public static func noteId(of item: Item) -> String? {
        guard isSpokenNote(mediaType: item.mediaType) else { return nil }
        return noteId(fromReference: item.externalReference)
    }

    /// The Lock Screen and Now Playing subtitle for a note: plain words, never the `note://` reference. Nil for any
    /// other item, which keeps its own subtitle.
    public static func mediaSubtitle(for item: Item) -> String? {
        isSpokenNote(mediaType: item.mediaType) ? defaultTitle : nil
    }

    /// The Library item for a note. Its text is the note's transcript so far (empty until a take is transcribed), and
    /// it holds nothing else of the note, so rebuilding it from the store loses nothing.
    public static func makeItem(note: SpokenNote, title: String? = nil, createdAt: Date) -> Item {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Item(
            id: itemId(forNoteId: note.id),
            title: trimmed.isEmpty ? defaultTitle : trimmed,
            mediaType: mediaType,
            text: note.text,
            externalReference: reference(forNoteId: note.id),
            status: "ready",
            externalReferenceType: referenceType,
            createdAt: createdAt
        )
    }
}
