import Foundation

/// The photo a listener took for a live-session Margin, as it belongs to that Margin once the session is saved as a
/// Library item (#4180). The saved Margin is an ordinary database row with no photo field; the link back is the item's
/// `LiveSessionRecord`, whose `savedMarginIds` maps each live Margin id to the saved one. Nothing here is written to
/// the database or a packet.
public struct SavedMarginPhoto: Equatable, Sendable {
    public var photo: LiveSessionPhoto
    /// The live Margin's "where I am", kept for the text alternative.
    public var whereNote: String?
    /// The live Margin's place, kept for the text alternative.
    public var place: LiveSessionPlace?

    public init(photo: LiveSessionPhoto, whereNote: String?, place: LiveSessionPlace?) {
        self.photo = photo
        self.whereNote = whereNote
        self.place = place
    }

    /// The text alternative, from the saved Margin's words as they are now (Tidy or Transcribe again can change them
    /// after the session), falling back to the place and the "where I am" the live Margin had.
    public func altText(currentText: String) -> String {
        LiveSessionPhoto.altText(text: currentText, whereNote: whereNote, place: place)
    }

    /// The text alternative for the saved Margin: its shown words, else its cleaned transcript, else its transcript.
    /// A spoken Margin still transcribing has none of them and falls back to the place, never "Audio Margin".
    public func altText(for margin: Interjection) -> String {
        let words = [margin.displayText, margin.cleanedTranscript, margin.transcript]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return altText(currentText: words ?? "")
    }
}

/// Every saved live-session photo, keyed by the saved Margin's id (#4180). One value for the whole app: built from the
/// records once per launch (`load(from:)`, off the main thread), then kept current by `add` on a save and `remove` on
/// a purge. `merging(loaded:touchedItemIds:)` lets a save or purge that lands while the launch load is still reading
/// survive it.
public struct SavedMarginPhotos: Equatable, Sendable {
    public private(set) var byMarginId: [String: SavedMarginPhoto] = [:]
    public private(set) var marginIdsByItem: [String: [String]] = [:]

    public init(records: [LiveSessionRecord]) {
        for record in records { add(record) }
    }

    public func photo(forMarginId id: String) -> SavedMarginPhoto? { byMarginId[id] }

    /// Adds the record's photos, replacing whatever that item had before.
    ///
    /// A live Margin counts only when its photo keeps the rules (`validPhoto`) and its id is a key in
    /// `savedMarginIds`; the entry is stored under the saved id. A record saved before the links were kept (nil
    /// `savedMarginIds`) adds nothing. When two live Margins map to one saved id, the first in session order wins.
    public mutating func add(_ record: LiveSessionRecord) {
        remove(itemId: record.itemId)
        guard let links = record.savedMarginIds else { return }
        var ids: [String] = []
        for margin in record.session.margins {
            guard let photo = margin.validPhoto, let savedId = links[margin.id] else { continue }
            // An id another item already holds stays with that item, so removing one item never strips the other.
            guard byMarginId[savedId] == nil else { continue }
            byMarginId[savedId] = SavedMarginPhoto(photo: photo, whereNote: margin.whereNote, place: margin.place)
            ids.append(savedId)
        }
        if !ids.isEmpty { marginIdsByItem[record.itemId] = ids }
    }

    public mutating func remove(itemId: String) {
        guard let ids = marginIdsByItem.removeValue(forKey: itemId) else { return }
        for id in ids { byMarginId[id] = nil }
    }

    /// The launch-load merge: items nobody touched since the load began come from `loaded`; items saved or purged
    /// meanwhile (`touchedItemIds`) keep what `self` holds now, which is nothing for a purged one.
    public func merging(loaded: SavedMarginPhotos, touchedItemIds: Set<String>) -> SavedMarginPhotos {
        var result = SavedMarginPhotos(records: [])
        // Touched items go in first, so on a (corrupt) id two items both name, the newer save keeps it.
        for itemId in touchedItemIds.sorted() {
            guard let ids = marginIdsByItem[itemId] else { continue }
            result.insert(itemId: itemId, ids: ids, from: self)
        }
        for (itemId, ids) in loaded.marginIdsByItem.sorted(by: { $0.key < $1.key }) where !touchedItemIds.contains(itemId) {
            result.insert(itemId: itemId, ids: ids, from: loaded)
        }
        return result
    }

    private mutating func insert(itemId: String, ids: [String], from source: SavedMarginPhotos) {
        var kept: [String] = []
        for id in ids {
            guard byMarginId[id] == nil, let entry = source.byMarginId[id] else { continue }
            byMarginId[id] = entry
            kept.append(id)
        }
        if !kept.isEmpty { marginIdsByItem[itemId] = kept }
    }

    /// Reads every saved session's record under `directory` (the folder `LiveSessionRecord.save(in:)` writes to). A
    /// missing folder gives an empty lookup. It reads files, so call it off the main thread.
    public nonisolated static func load(from directory: URL) -> SavedMarginPhotos {
        // Sorted by item id so the result doesn't depend on the order the file system lists the records in.
        SavedMarginPhotos(records: LiveSessionRecord.loadAll(from: directory).sorted { $0.itemId < $1.itemId })
    }
}
