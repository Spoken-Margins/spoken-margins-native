import Foundation

/// What a Library folder remembers about the folder it came from (#3769): where it was picked, which files it holds and
/// in what state, and what could not be added.
///
/// A Library folder is an `ItemCollection` (the name and the item IDs) plus one of these, saved as a separate record of
/// kind `library_folder` under the same ID. An older build never reads or writes that record, so it sees an ordinary
/// collection, and editing the collection there cannot strip anything from this record. The collection's `itemIDs` stay the
/// truth for who is in the folder; this record keeps only states, hashes and paths (`LibraryFolderLaunchRule` reconciles them).
/// Nothing here can lose an item or a Margin: the record names items, it never owns them.
///
/// Write order for a new folder: the collection first, then this record, so an interruption between the two leaves an
/// ordinary collection instead of a record with nothing behind it (`LibraryFolderOrphanRule` drops the latter at launch).
public struct LibraryFolderRecord: Codable, Equatable, Sendable, Identifiable {
    public static let recordKind = "library_folder"
    /// Shown for a file the app was ended in the middle of adding.
    public static let stoppedReason = "Import stopped before this was added."

    public enum Source: Codable, Equatable, Sendable {
        /// Picked in `+ > Import from Files`.
        case files
        /// A subfolder of a Quick Folder, named as that Quick Folder is (PR 8).
        case quickFolder(name: String)
    }

    public enum MemberState: String, Codable, Equatable, Sendable {
        case adding
        case added
        case failed
        /// The listener took it out with "Remove from Folder". It stays here so a re-import never adopts it back.
        case removed
    }

    public struct Member: Codable, Equatable, Sendable {
        /// Unique in the folder. The relative path in NFC for a file, `path#NNN` for a link-list entry, and
        /// `path#updated-N` for a newer copy of a changed file.
        public var key: String
        public var kind: LibraryFolderWalk.Kind
        /// The file name, or a link entry's title (its address when it has none).
        public var name: String
        /// Hex SHA-256 of the file's bytes. Nil for a link entry and for a file that was not on the device yet.
        public var sha256: String?
        /// A link entry's https address, which is its identity.
        public var address: String?
        /// The Library item. Known before the item is saved for text, PDF, EPUB and audio; recorded when the importer
        /// returns for an edition (its content hash) and for a link. Nil for a member that failed before it was known.
        public var itemID: String?
        /// When the folder first listed it.
        public var addedAt: Date
        public var state: MemberState
        /// Why it failed, in the words "Couldn't add" shows.
        public var reason: String?
        /// Whether "Try Again" is offered. Merging tries every failed member again either way.
        public var retryable: Bool
        /// The key of the member this one is a newer copy of ("Updated copy").
        public var updatedCopyOf: String?

        public init(
            key: String, kind: LibraryFolderWalk.Kind, name: String, sha256: String? = nil, address: String? = nil,
            itemID: String? = nil, addedAt: Date, state: MemberState = .adding, reason: String? = nil,
            retryable: Bool = false, updatedCopyOf: String? = nil
        ) {
            self.key = key
            self.kind = kind
            self.name = name
            self.sha256 = sha256
            self.address = address
            self.itemID = itemID
            self.addedAt = addedAt
            self.state = state
            self.reason = reason
            self.retryable = retryable
            self.updatedCopyOf = updatedCopyOf
        }
    }

    /// Something in the picked folder that is not a member and will not become one, such as a Margins packet. Replaced
    /// by every walk, so it always describes the folder as last read.
    public struct NotAdded: Codable, Equatable, Sendable {
        public var key: String
        public var name: String
        public var reason: String

        public init(key: String, name: String, reason: String) {
            self.key = key
            self.name = name
            self.reason = reason
        }
    }

    /// The same as the collection's ID.
    public let id: String
    /// The picked URL's standardized path (`standardizedPath(of:)`). "The same folder again" means this matches.
    public var sourcePath: String
    /// The folder's security-scoped bookmark, kept for "Try Again". Nil when the system gave none.
    public var bookmark: Data?
    public var source: Source
    public var importedAt: Date
    /// Set when the listener deletes the folder. A deleted folder never matches a new pick, and its name still counts
    /// when a new folder is named.
    public var trashedAt: Date?
    /// Files of kinds the app can't read (images and the like): counted, not named.
    public var skippedOtherCount: Int
    /// Loose items that already were in the Library and moved into the folder instead of being copied.
    public var adoptedCount: Int
    /// The folder held more than the walk's limits allow, so some of it was not looked at.
    public var capped: Bool
    public var notAdded: [NotAdded]
    /// In folder order.
    public var members: [Member]

    public init(
        id: String, sourcePath: String, bookmark: Data? = nil, source: Source = .files, importedAt: Date,
        trashedAt: Date? = nil, skippedOtherCount: Int = 0, adoptedCount: Int = 0, capped: Bool = false,
        notAdded: [NotAdded] = [], members: [Member] = []
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.bookmark = bookmark
        self.source = source
        self.importedAt = importedAt
        self.trashedAt = trashedAt
        self.skippedOtherCount = skippedOtherCount
        self.adoptedCount = adoptedCount
        self.capped = capped
        self.notAdded = notAdded
        self.members = members
    }

    public var isTrashed: Bool { trashedAt != nil }

    /// The path two picks of the same folder share: standardized, in NFC.
    public static func standardizedPath(of url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

// MARK: - Naming

/// Names a new Library folder so it never clashes with a collection or another folder (#3769). Folders are collections,
/// so passing every collection covers folders, deleted ones included.
public enum LibraryFolderNaming {
    /// `raw` as `ItemCollectionEditing` would save it, or with " 2", " 3" and so on added until no collection has that
    /// name (ignoring case and accents). The base is cut when the suffix would push the name past the limit. Nil when
    /// `raw` is empty.
    public static func uniqueName(_ raw: String, in collections: [ItemCollection]) -> String? {
        guard let base = ItemCollectionEditing.normalizedName(raw) else { return nil }
        if !ItemCollectionEditing.isNameTaken(base, in: collections) { return base }
        var number = 2
        while true {
            let suffix = " \(number)"
            let room = ItemCollectionEditing.maximumNameCharacters - suffix.count
            let trimmed = String(base.prefix(max(room, 1))).trimmingCharacters(in: .whitespaces)
            let candidate = trimmed + suffix
            if !ItemCollectionEditing.isNameTaken(candidate, in: collections) { return candidate }
            number += 1
        }
    }
}

// MARK: - Launch and orphans

/// What to do with folder records when the app starts (#3769).
public enum LibraryFolderLaunchRule {
    public struct Resolution: Equatable, Sendable {
        public var record: LibraryFolderRecord
        /// The collection, with any repair applied. Equal to the one passed in when nothing needed repair.
        public var collection: ItemCollection
    }

    /// Settles the states an interrupted import or an older build left behind. The collection's `itemIDs` are the truth
    /// for who is in the folder.
    ///
    /// 1. A member still `adding` becomes `added` when its item exists, and is put into the collection if the app was
    ///    ended between saving the item and adding it there. With no item (or none known), it becomes `failed` with
    ///    "Import stopped before this was added." and can be tried again.
    /// 2. A member that was `added` but is no longer in the collection becomes `removed`: an older build took it out, so a
    ///    re-import must not adopt it back.
    ///
    /// `existingItemIDs` holds every item in the Library, deleted ones included.
    public static func resolved(
        _ record: LibraryFolderRecord, collection: ItemCollection, existingItemIDs: Set<String>
    ) -> Resolution {
        var record = record
        var collection = collection
        let inCollection = Set(collection.itemIDs)
        for index in record.members.indices {
            var member = record.members[index]
            switch member.state {
            case .adding:
                if let itemID = member.itemID, existingItemIDs.contains(itemID) {
                    member.state = .added
                    member.reason = nil
                    if !inCollection.contains(itemID) { collection.itemIDs.append(itemID) }
                } else {
                    member.state = .failed
                    member.reason = LibraryFolderRecord.stoppedReason
                    member.retryable = true
                }
            case .added:
                if let itemID = member.itemID, !inCollection.contains(itemID) { member.state = .removed }
            case .failed, .removed:
                break
            }
            record.members[index] = member
        }
        return Resolution(record: record, collection: collection)
    }
}

/// A record whose collection is gone, because an older build deleted the collection (#3769). The items stay as loose rows;
/// only the record goes.
public enum LibraryFolderOrphanRule {
    public static func orphanedFolderIDs(folders: [LibraryFolderRecord], collections: [ItemCollection]) -> [String] {
        let known = Set(collections.map(\.id))
        return folders.map(\.id).filter { !known.contains($0) }
    }
}
