import Foundation

/// A named group of Library items, such as a course, a club or a project (#208, #489).
///
/// A collection only references items by ID. Deleting it never deletes an item or its Margins,
/// and deleting an item leaves the collection's reference behind for the caller to ignore.
public struct ItemCollection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    /// Items in the listener's order. An item appears once.
    public var itemIDs: [String] {
        didSet { itemIDs = Self.uniqued(itemIDs) }
    }
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, itemIDs: [String] = [], createdAt: Date, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.itemIDs = Self.uniqued(itemIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private static func uniqued(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Answers "is this item in the collection?" for filters such as the Margins scope.
public struct ItemCollectionScope: Sendable, Equatable {
    public let collectionID: String
    private let itemIDs: Set<String>

    public init(_ collection: ItemCollection) {
        collectionID = collection.id
        itemIDs = Set(collection.itemIDs)
    }

    public func contains(itemID: String) -> Bool {
        itemIDs.contains(itemID)
    }
}
