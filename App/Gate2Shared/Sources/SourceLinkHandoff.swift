import Foundation

public struct SourceLinkHandoff: Codable, Equatable, Sendable {
    public var id: String
    public var schemaVersion: String
    public var inputURL: String
    public var sourceSurface: String
    public var startSession: Bool

    public init(
        id: String,
        schemaVersion: String = "source-link-handoff.v1",
        inputURL: String,
        sourceSurface: String,
        startSession: Bool = true
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.inputURL = inputURL
        self.sourceSurface = sourceSurface
        self.startSession = startSession
    }
}

public enum SourceLinkHandoffStoreError: Error, Equatable, LocalizedError {
    case appGroupUnavailable(String)
    case invalidPayload(String)
    case missingPayload(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "App Group unavailable: \(identifier)"
        case .invalidPayload(let message):
            return "Invalid source link payload: \(message)"
        case .missingPayload(let id):
            return "Missing source link payload: \(id)"
        }
    }
}

public struct SourceLinkHandoffStore {
    public static let appGroupIdentifier = "group.com.spokenmargins.native"

    private static let payloadDirectoryName = "SourceLinkHandoffs"
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public static func appGroup(fileManager: FileManager = .default) throws -> SourceLinkHandoffStore {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw SourceLinkHandoffStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        return SourceLinkHandoffStore(baseDirectory: containerURL, fileManager: fileManager)
    }

    @discardableResult
    public func save(_ handoff: SourceLinkHandoff) throws -> String {
        let cleaned = try validated(handoff)
        let directory = baseDirectory.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(cleaned.id).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cleaned).write(to: url, options: [.atomic])
        return cleaned.id
    }

    public func handoff(payloadID: String) throws -> SourceLinkHandoff {
        let id = payloadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw SourceLinkHandoffStoreError.invalidPayload("payloadId is empty")
        }
        let url = baseDirectory
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw SourceLinkHandoffStoreError.missingPayload(id)
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SourceLinkHandoff.self, from: data)
        guard decoded.id == id else {
            throw SourceLinkHandoffStoreError.invalidPayload("payload id does not match payloadId")
        }
        return try validated(decoded)
    }

    public func pendingPayloadIDs() throws -> [String] {
        let directory = baseDirectory.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return lhsDate < rhsDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    public func deletePayload(payloadID: String) throws {
        let id = payloadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let url = baseDirectory
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("json")
        try? fileManager.removeItem(at: url)
    }

    private func validated(_ handoff: SourceLinkHandoff) throws -> SourceLinkHandoff {
        let id = handoff.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputURL = handoff.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceSurface = handoff.sourceSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw SourceLinkHandoffStoreError.invalidPayload("id is required")
        }
        guard !inputURL.isEmpty, URL(string: inputURL) != nil else {
            throw SourceLinkHandoffStoreError.invalidPayload("inputURL is required")
        }
        guard !sourceSurface.isEmpty else {
            throw SourceLinkHandoffStoreError.invalidPayload("sourceSurface is required")
        }
        return SourceLinkHandoff(
            id: id,
            schemaVersion: handoff.schemaVersion,
            inputURL: inputURL,
            sourceSurface: sourceSurface,
            startSession: handoff.startSession
        )
    }
}

public enum SourceLinkHandoffURL {
    public static let scheme = "spokenmargins"
    public static let host = "source-link"

    public static func isSourceLinkURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host
    }

    public static func url(forPayloadID payloadID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "payloadId", value: payloadID)]
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func url(for handoff: SourceLinkHandoff) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "inputURL", value: handoff.inputURL),
            URLQueryItem(name: "sourceSurface", value: handoff.sourceSurface),
            URLQueryItem(name: "startSession", value: handoff.startSession ? "1" : "0")
        ]
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func payloadID(from url: URL) -> String? {
        guard isSourceLinkURL(url) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "payloadId" })?
            .value
    }

    public static func handoff(from url: URL) -> SourceLinkHandoff? {
        guard isSourceLinkURL(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let inputURL = items.first(where: { $0.name == "inputURL" })?.value,
              !inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let sourceSurface = items.first(where: { $0.name == "sourceSurface" })?.value ?? "url"
        let startSession = items.first(where: { $0.name == "startSession" })?.value != "0"
        return SourceLinkHandoff(
            id: "source-link-\(Int(Date().timeIntervalSince1970))",
            inputURL: inputURL,
            sourceSurface: sourceSurface,
            startSession: startSession
        )
    }

    public static func handoff(from url: URL, store: SourceLinkHandoffStore) throws -> SourceLinkHandoff {
        guard let payloadID = payloadID(from: url) else {
            guard let handoff = handoff(from: url) else {
                throw SourceLinkHandoffStoreError.invalidPayload("unsupported source link URL")
            }
            return handoff
        }
        return try store.handoff(payloadID: payloadID)
    }
}
