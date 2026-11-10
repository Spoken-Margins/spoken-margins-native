import Foundation

/// The edits the "Add to Collection" sheet makes, as pure functions so they can be tested without the app (#490).
/// Each returns the collection to save, or nil when the edit isn't allowed; nothing here touches the store.
public enum ItemCollectionEditing {
    public static let maximumNameCharacters = 60

    /// The name as it will be saved: trimmed, runs of whitespace made one space, cut to a sane length. nil when empty.
    public static func normalizedName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(maximumNameCharacters))
    }

    /// Two collections can't share a name, ignoring case and accents. `excluding` is the collection being renamed.
    public static func isNameTaken(_ name: String, in collections: [ItemCollection], excluding id: String? = nil) -> Bool {
        let wanted = fold(name)
        return collections.contains { $0.id != id && fold($0.name) == wanted }
    }

    /// A new collection holding `itemID`, if the name is usable.
    public static func creating(
        name: String, itemID: String?, id: String, now: Date, in collections: [ItemCollection]
    ) -> ItemCollection? {
        guard let name = normalizedName(name), !isNameTaken(name, in: collections) else { return nil }
        return ItemCollection(id: id, name: name, itemIDs: itemID.map { [$0] } ?? [], createdAt: now)
    }

    public static func renaming(_ collection: ItemCollection, to name: String, now: Date, in collections: [ItemCollection]) -> ItemCollection? {
        guard let name = normalizedName(name), !isNameTaken(name, in: collections, excluding: collection.id) else { return nil }
        var renamed = collection
        renamed.name = name
        renamed.updatedAt = now
        return renamed
    }

    /// Adds the item at the end of the collection, or takes it out when it is already there.
    public static func toggling(itemID: String, in collection: ItemCollection, now: Date) -> ItemCollection {
        var edited = collection
        if edited.itemIDs.contains(itemID) {
            edited.itemIDs.removeAll { $0 == itemID }
        } else {
            edited.itemIDs.append(itemID)
        }
        edited.updatedAt = now
        return edited
    }

    private static func fold(_ name: String) -> String {
        (normalizedName(name) ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension MarginCollectionQuery {
    /// Tags a Margins scope picker uses: an item's ID for one item, this prefix plus the ID for a collection.
    public static let collectionTagPrefix = "collection:"

    /// The picker's current choice: nil for all items.
    public var scopeTag: String? {
        collection.map { Self.collectionTagPrefix + $0.collectionID } ?? itemID
    }

    /// Applies the picker's choice. A collection and a single item are never both in scope.
    public mutating func selectScope(tag: String?, collections: [ItemCollection]) {
        collection = nil
        itemID = nil
        guard let tag else { return }
        guard tag.hasPrefix(Self.collectionTagPrefix) else {
            itemID = tag
            return
        }
        let id = String(tag.dropFirst(Self.collectionTagPrefix.count))
        collection = collections.first { $0.id == id }.map(ItemCollectionScope.init)
    }

    /// Brings the scope up to date after the collections changed: new items count, and a deleted collection
    /// stops being the scope.
    public mutating func refreshCollection(from collections: [ItemCollection]) {
        guard let current = collection else { return }
        collection = collections.first { $0.id == current.collectionID }.map(ItemCollectionScope.init)
    }
}
