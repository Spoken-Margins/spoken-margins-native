import Foundation

/// The random sender id a packet can carry, so a listener can hide every Margin from one sender on their own phone
/// (#2846 item 2, #1729). Owner's call 2026-10-17 (#1729 item 14): one id per friendship or group, made the first time
/// the listener shares with that group; nothing links a sender across groups. The id is random, never derived from a
/// name, an account or a device, and it never leaves a phone except inside the packets that listener shares.
///
/// The packet carries it as an optional artifact (`required: false`), so the last shipped build skips it and imports
/// the Margins as it always did (the manifest itself rejects unknown fields, so it can't go there).
public struct SenderIdentityArtifact: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = "spoken-margins.sender-identity.v1"

    public let id: String
    public let schemaVersion: String
    public let senderId: String

    public init(
        id: String = "sender-identity",
        schemaVersion: String = SenderIdentityArtifact.schemaVersion,
        senderId: String
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.senderId = senderId
    }
}

public enum SenderID {
    /// Letters, digits, `-` and `_`, 16 to 64 characters. Generated ids are 32 lowercase hex characters, but the
    /// reader accepts the wider range so a later writer can change the form without locking this build out.
    public static func isValid(_ value: String) -> Bool {
        guard (16...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }

    /// `value` itself when it is a sender id, else nil: what a layer may keep as its sender.
    public static func valid(_ value: String?) -> String? {
        value.flatMap { isValid($0) ? $0 : nil }
    }

    /// 16 random bytes as 32 lowercase hex characters.
    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }
}

/// One sender id per friendship or group, made the first time the listener shares with that group and then kept, so
/// the same friends always see the same id and different groups never share one.
public struct SenderIDLedger: Codable, Equatable, Sendable {
    public private(set) var idsByGroup: [String: String]

    public init(idsByGroup: [String: String] = [:]) {
        // Two groups with one id would link them, so a repeat keeps only one group (the first by name).
        var seen = Set<String>()
        var kept: [String: String] = [:]
        for (group, id) in idsByGroup.sorted(by: { $0.key < $1.key }) where SenderID.isValid(id) && seen.insert(id).inserted {
            kept[group] = id
        }
        self.idsByGroup = kept
    }

    // A saved file goes through the same checks as a new value.
    private enum CodingKeys: String, CodingKey { case idsByGroup }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(idsByGroup: try values.decode([String: String].self, forKey: .idsByGroup))
    }

    /// The group's id, made now when the group has none. `groupKey` is whatever the app uses to name a group on this
    /// phone; it is never sent anywhere.
    public mutating func senderID(forGroup groupKey: String, makeID: () -> String = { SenderID.generate() }) -> String {
        if let existing = idsByGroup[groupKey] { return existing }
        var candidate = makeID()
        // A bad or repeated id from the maker would let two groups be linked or write an id readers refuse, so it
        // is replaced by a random one (16 random bytes, so a repeat is not a practical worry).
        while !SenderID.isValid(candidate) || idsByGroup.values.contains(candidate) {
            candidate = SenderID.generate()
        }
        idsByGroup[groupKey] = candidate
        return candidate
    }
}

/// The senders this listener has hidden, on this device only (#2846). Hiding follows the sender's id, so it covers
/// every item and every later import, and unhiding brings them all back: nothing is deleted.
public struct HiddenSenders: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable, Identifiable {
        public let senderId: String
        /// The label the sender gave themselves when the listener hid them, so Settings can say who it is.
        public let displayLabel: String?
        public let hiddenAt: Date
        public var id: String { senderId }

        public init(senderId: String, displayLabel: String?, hiddenAt: Date) {
            self.senderId = senderId
            self.displayLabel = displayLabel
            self.hiddenAt = hiddenAt
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        var seen = Set<String>()
        self.entries = entries.filter { SenderID.isValid($0.senderId) && seen.insert($0.senderId).inserted }
    }

    // A saved file goes through the same checks as a new value.
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try values.decode([Entry].self, forKey: .entries))
    }

    /// Newest first, the order Settings lists them in.
    public var listed: [Entry] { entries.sorted { $0.hiddenAt > $1.hiddenAt } }

    public func isHidden(_ senderId: String?) -> Bool {
        guard let senderId else { return false }
        return entries.contains { $0.senderId == senderId }
    }

    /// Hides `senderId`; false (and no change) when it is not a sender id, which a layer without one never has.
    @discardableResult
    public mutating func hide(_ senderId: String?, displayLabel: String? = nil, at date: Date = Date()) -> Bool {
        guard let id = SenderID.valid(senderId) else { return false }
        if !isHidden(id) { entries.append(Entry(senderId: id, displayLabel: displayLabel, hiddenAt: date)) }
        return true
    }

    public mutating func unhide(_ senderId: String) {
        entries.removeAll { $0.senderId == senderId }
    }

    public func isHidden(_ layer: ImportedCommentaryLayer) -> Bool {
        isHidden(layer.senderId)
    }

    /// The layers to show: those not from a hidden sender. A layer with no sender id is always shown, because nothing
    /// says who it is from.
    public func visible(_ layers: [ImportedCommentaryLayer]) -> [ImportedCommentaryLayer] {
        guard !entries.isEmpty else { return layers }
        return layers.filter { !isHidden($0) }
    }
}

/// Keeps a small Codable value as one JSON file, written atomically. A missing or damaged file reads as `empty`:
/// for the hidden list that shows a sender again, and for the ledger it makes a new id the next time the listener
/// shares, neither of which loses a Margin.
public struct SenderIdentityFileStore<Value: Codable & Sendable>: Sendable {
    public let fileURL: URL
    private let empty: Value

    public init(fileURL: URL, empty: Value) {
        self.fileURL = fileURL
        self.empty = empty
    }

    public func load() -> Value {
        guard let data = try? Data(contentsOf: fileURL) else { return empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Value.self, from: data)) ?? empty
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }
}

extension SenderIdentityFileStore where Value == HiddenSenders {
    public static func hiddenSenders(in directory: URL) -> Self {
        .init(fileURL: directory.appendingPathComponent("hidden-senders.json"), empty: HiddenSenders())
    }
}

extension SenderIdentityFileStore where Value == SenderIDLedger {
    public static func ledger(in directory: URL) -> Self {
        .init(fileURL: directory.appendingPathComponent("sender-ids.json"), empty: SenderIDLedger())
    }

    /// The group every share belongs to: one id per phone (owner's call 2026-11-05 on #2846; the app doesn't know who a
    /// share goes to, and a group step would cost the two-tap share). The id is random and made on first use.
    public static var phoneGroup: String { "this-phone" } // not stored: a generic type has no static stored property

    /// The id this phone puts in the packets it shares: made the first time and kept in the ledger file after that, so a
    /// friend who hides this sender once hides every later share too. The file can't be written, or was damaged: the
    /// share still goes out with a fresh id, and the friend can hide this one too (a Margin is never held back for it).
    public func phoneSenderID(makeID: () -> String = { SenderID.generate() }) -> String {
        var ledger = load()
        let existed = ledger.idsByGroup[Self.phoneGroup] != nil
        let id = ledger.senderID(forGroup: Self.phoneGroup, makeID: makeID)
        if !existed { try? save(ledger) }
        return id
    }
}
