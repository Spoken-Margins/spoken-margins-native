import Foundation

/// A share link this app sent (#5275), kept so the sender's Margins tab can say "Link sent" and, once a friend
/// opened it, "Opened". It holds the link's id and opened-token, never the URL or the key, so nothing in it can
/// open the Margins. It is forgotten when the link expires.
public struct SentShareLink: Codable, Equatable, Sendable {
    public let id: String
    public let token: String
    public let itemID: String
    public let createdAt: Date
    public let expiresAt: Date
    public var opened: Bool
    public var lastCheckedAt: Date?

    public init(id: String, token: String, itemID: String, createdAt: Date, expiresAt: Date, opened: Bool = false, lastCheckedAt: Date? = nil) {
        self.id = id
        self.token = token
        self.itemID = itemID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.opened = opened
        self.lastCheckedAt = lastCheckedAt
    }

    /// The record for a link the server just made, or nil for a link with no key (it can't have a token).
    public init?(link: URL, serverExpiresAt: String?, itemID: String, createdAt: Date) {
        guard let parsed = ShareLinkURL(url: link), let token = ShareLinkOpenedToken.make(for: parsed) else { return nil }
        self.init(id: parsed.id, token: token, itemID: itemID, createdAt: createdAt,
                  expiresAt: Self.expiry(serverValue: serverExpiresAt, createdAt: createdAt))
    }

    public func isLive(at now: Date) -> Bool { now < expiresAt }

    /// The server's `expiresAt` (Go's RFC 3339, with or without fractional seconds), or 30 days after
    /// `createdAt` when it is missing or unreadable.
    public static func expiry(serverValue: String?, createdAt: Date) -> Date {
        if let serverValue {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: serverValue) ?? ISO8601DateFormatter().date(from: serverValue) {
                return date
            }
        }
        return createdAt.addingTimeInterval(30 * 24 * 60 * 60)
    }
}

/// The sent-link records' file: `Application Support/sent-share-links.json`, written atomically. A JSON file and
/// not SQLite, so the previous build's database is untouched (#5275, Default 12). A corrupt file reads as empty;
/// expired records are dropped at load.
public struct SentShareLinkFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard(fileManager: FileManager = .default) -> SentShareLinkFile {
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        return SentShareLinkFile(url: support.appendingPathComponent("sent-share-links.json"))
    }

    public func load(now: Date) -> [SentShareLink] {
        guard let data = try? Data(contentsOf: url),
              let records = try? Self.decoder.decode([SentShareLink].self, from: data) else { return [] }
        return records.filter { $0.isLive(at: now) }
    }

    public func save(_ records: [SentShareLink]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(records).write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// The switch and the rules for opened marks (#5275).
public enum ShareLinkOpenedPolicy {
    /// App Settings' "Show when links are opened". One switch for both ends: off sends no mark from this app,
    /// asks about no link, shows no "Opened" and no arrival notice.
    public static let defaultsKey = "shareLinkOpenedReceipts"
    /// A record is asked about at most this often.
    public static let checkInterval: TimeInterval = 10 * 60
    /// At most this many records are asked about each time the Margins tab appears.
    public static let checksPerAppearance = 20

    /// On unless the listener turned it off. Never `bool(forKey:)`, which reads an unset key as off.
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The records to ask the server about now: live, not seen opened, not asked in the last ten minutes,
    /// newest first, at most twenty. None while the switch is off. A record seen opened is never asked again,
    /// so a later takedown can't change what the sender sees.
    public static func checksToRun(_ records: [SentShareLink], receiptsOn: Bool, now: Date) -> [SentShareLink] {
        guard receiptsOn else { return [] }
        let due = records.filter { record in
            record.isLive(at: now) && !record.opened &&
                (record.lastCheckedAt.map { now.timeIntervalSince($0) >= checkInterval || $0 > now } ?? true)
        }
        return Array(due.sorted { $0.createdAt > $1.createdAt }.prefix(checksPerAppearance))
    }
}
