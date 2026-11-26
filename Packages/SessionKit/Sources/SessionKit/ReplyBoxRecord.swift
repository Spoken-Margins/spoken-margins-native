import Foundation

/// What the sender's phone keeps for one reply box (#4675, `docs/design/reply-mailbox.md` piece 3). Its own record kind,
/// `reply_box`, with no item_id: no table or index changes, schema 5 stays, an older build never queries the kind, and
/// deleting an item never deletes one. It stays on the phone that made the link (never synced). `K` is kept here,
/// protected like the rest of the database: it opens only answers sent to this phone, and only until the box ends.
public struct ReplyBoxRecord: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible {
    public static let recordKind = "reply_box"
    /// The server keeps a link 30 days (`internal/links/store.go`).
    public static let linkLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// Answers can still be fetched for 7 days after the link ends.
    public static let readGrace: TimeInterval = 7 * 24 * 60 * 60

    /// One answer imported from the box: its post number and the commentary layer it became.
    public struct Answer: Codable, Equatable, Hashable, Sendable {
        public var seq: Int
        public var layerId: String

        public init(seq: Int, layerId: String) {
            self.seq = seq
            self.layerId = layerId
        }
    }

    /// The box id, which is the record id.
    public var id: String { boxId }
    public var linkId: String
    public var boxId: String
    /// `K` in base64url, no padding.
    public var key: String
    /// The shared item in the sender's Library. Only answers placed on it get in.
    public var itemId: String
    /// The digest of the package the link carried. An answer that names a parent must name this package.
    public var sharedPackageDigest: String
    public var createdAt: Date
    /// When the link, and so posting to the box, ends.
    public var expiresAt: Date
    /// The number of the last post dealt with, imported or dropped or skipped.
    public var cursor: Int
    /// The sender stopped answers through this link.
    public var closed: Bool
    public var closedAt: Date?
    /// The server said the box has ended (`410`). Nothing more is fetched.
    public var ended: Bool
    /// The last check of this box that finished, so every open box gets its turn.
    public var lastChecked: Date?
    public var answers: [Answer]

    public init(
        box: ReplyBox, linkId: String, itemId: String, sharedPackageDigest: String, createdAt: Date, expiresAt: Date,
        cursor: Int = 0, closed: Bool = false, closedAt: Date? = nil, ended: Bool = false, lastChecked: Date? = nil,
        answers: [Answer] = []
    ) {
        self.linkId = linkId
        self.boxId = box.id
        self.key = box.key.fragment
        self.itemId = itemId
        self.sharedPackageDigest = sharedPackageDigest
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.cursor = max(0, cursor)
        self.closed = closed
        self.closedAt = closedAt
        self.ended = ended
        self.lastChecked = lastChecked
        self.answers = answers
    }

    /// The box, from `K`. Nil when the saved key is damaged, or is not this box's key.
    public var box: ReplyBox? {
        guard let key = ReplyBox.Key(fragment: key) else { return nil }
        let box = ReplyBox(key: key)
        return box.id == boxId ? box : nil
    }

    /// Answers can be fetched until a week after the link ends.
    public var readsUntil: Date { expiresAt.addingTimeInterval(Self.readGrace) }

    /// Whether a check may still read this box at `now`: not ended, inside the read window, and not a closed box that
    /// has been checked once since it was closed (nothing new can arrive after a close).
    public func isOpenForChecks(at now: Date) -> Bool {
        guard !ended, now < readsUntil else { return false }
        if closed, let closedAt, let lastChecked, lastChecked >= closedAt { return false }
        return true
    }

    /// The retention rule: kept until a week after the link ends; after that, kept while any answer's layer is still in
    /// the Library (so Report keeps working), and deleted once none is.
    public func shouldDelete(at now: Date, layerIsInLibrary: (String) -> Bool) -> Bool {
        guard now >= readsUntil else { return false }
        return !answers.contains { layerIsInLibrary($0.layerId) }
    }

    /// Whether `layerId` came through this box: the card shows "Report this answer" and "Stop answers" only for these.
    public func carries(layerId: String) -> Bool {
        answers.contains { $0.layerId == layerId }
    }

    /// The record after the sender stopped answers.
    public func markingClosed(at date: Date) -> ReplyBoxRecord {
        var copy = self
        if !copy.closed {
            copy.closed = true
            copy.closedAt = date
        }
        return copy
    }

    /// Never prints `K`.
    public var description: String { "ReplyBoxRecord(boxId: \(boxId), linkId: \(linkId), …)" }

    // A record a later build wrote with fields this one doesn't know, or without the optional ones, still reads.
    private enum CodingKeys: String, CodingKey {
        case linkId, boxId, key, itemId, sharedPackageDigest, createdAt, expiresAt, cursor, closed, closedAt, ended
        case lastChecked, answers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linkId = try container.decode(String.self, forKey: .linkId)
        boxId = try container.decode(String.self, forKey: .boxId)
        key = try container.decode(String.self, forKey: .key)
        itemId = try container.decode(String.self, forKey: .itemId)
        sharedPackageDigest = try container.decode(String.self, forKey: .sharedPackageDigest)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        cursor = max(0, try container.decodeIfPresent(Int.self, forKey: .cursor) ?? 0)
        closed = try container.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        ended = try container.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
        answers = (try? container.decodeIfPresent([LossyAnswer].self, forKey: .answers))?.compactMap(\.answer) ?? []
    }

    private struct LossyAnswer: Decodable {
        let answer: Answer?
        init(from decoder: Decoder) throws { answer = try? Answer(from: decoder) }
    }

    /// The server's `expiresAt` (Go's RFC 3339, with or without fractional seconds).
    public static func parseServerDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Go writes up to nine fractional digits; Foundation reads three at most.
        guard let dot = text.firstIndex(of: "."),
              let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) else { return nil }
        let digits = text[text.index(after: dot)..<end]
        return fractional.date(from: String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + String(text[end...]))
    }
}

/// Where reply-box records are kept. `SQLiteSessionStore` keeps them (SessionKitPersistence); tests may pass their own.
public protocol ReplyBoxStoring: Sendable {
    func loadReplyBoxes() throws -> [ReplyBoxRecord]
    func saveReplyBox(_ record: ReplyBoxRecord) throws
    func deleteReplyBox(id: String) throws
    /// Reads one record, changes it and saves it as one step. Nil when there is no such record.
    @discardableResult
    func updateReplyBox(id: String, _ change: (inout ReplyBoxRecord) throws -> Void) throws -> ReplyBoxRecord?
}

/// The pure part of "only answers to the shared item get in" (`docs/design/reply-mailbox.md`, "Around it"). The app's
/// importer works out where a fetched packet would land; this says whether that may be kept.
public enum ReplyBoxAdmission {
    /// Why an answer was left out. `code` is the Diagnostics reason, which holds no content.
    public enum DropReason: String, Equatable, Hashable, Sendable, CaseIterable {
        /// The post didn't open with the box's key, or the box answered 404 for a post it listed.
        case unopenable = "unopenable"
        /// The packet isn't one this build can import.
        case unreadable = "unreadable"
        /// It would land on another item than the one shared.
        case otherItem = "other_item"
        /// The shared item is no longer in the Library.
        case itemMissing = "item_missing"
        /// Its `margin-conversation` part names a parent in another package than the one the link carried.
        case otherParent = "other_parent"
        /// It would need the review sheet (`SharedPacketArrival.route` → `.review`): a source the listener supplies or
        /// a Listening Map.
        case needsReview = "needs_review"
        /// The importer turned it down for a reason of its own.
        case rejected = "rejected"

        public var code: String { rawValue }

        /// The Diagnostics line: `reply_box.dropped reason=<code>`.
        public var diagnosticsLine: String { "reply_box.dropped reason=\(code)" }
    }

    /// Nil when the answer may be kept. `placedItemId` is where the importer would put it (nil when nowhere),
    /// `parentPackageDigests` every parent its `margin-conversation` part names (empty when it names none), and
    /// `route` how `SharedPacketArrival.route` would open it.
    public static func check(
        record: ReplyBoxRecord, placedItemId: String?, parentPackageDigests: [String], route: SharedPacketArrival.Route
    ) -> DropReason? {
        guard let placedItemId else { return .itemMissing }
        guard placedItemId == record.itemId else { return .otherItem }
        guard route == .openItem else { return .needsReview }
        guard parentPackageDigests.allSatisfy({ $0 == record.sharedPackageDigest }) else { return .otherParent }
        return nil
    }

    /// The same, reading the parents from the packet's `margin-conversation` artifact (nil when it has none).
    public static func check(
        record: ReplyBoxRecord, placedItemId: String?, conversation: MarginConversationArtifact?,
        route: SharedPacketArrival.Route
    ) -> DropReason? {
        check(
            record: record, placedItemId: placedItemId,
            parentPackageDigests: conversation?.replies.map(\.parentPackageDigest) ?? [], route: route
        )
    }
}
