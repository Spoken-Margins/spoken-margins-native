import Foundation

public enum Gate5BrowserTextHandoffStoreError: Error, Equatable, LocalizedError {
    case appGroupUnavailable(String)
    case missingPayload(String)
    case invalidPayload(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "Browser text App Group is unavailable: \(identifier)"
        case .missingPayload(let payloadID):
            return "Browser text payload was not found: \(payloadID)"
        case .invalidPayload(let reason):
            return "Browser text payload is invalid: \(reason)"
        }
    }
}

/// The browser-text payloads the Safari extension and Shortcuts leave in the App Group for the app to import,
/// and the ones that failed to import and wait to be retried. The folder is passed in, so the app group lookup
/// (and its legacy-build identifier) stays in the app. It holds a folder URL and `FileManager.default`, which is
/// safe to use from any thread; the app drains handoffs off the main thread (#2510).
public struct Gate5BrowserTextHandoffStore: @unchecked Sendable {
    private static let payloadDirectoryName = "BrowserTextHandoffs"
    private static let failedPayloadDirectoryName = "FailedBrowserTextHandoffs"

    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func save(_ handoff: BrowserTextHandoff, payloadID: String) throws {
        let id = payloadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("payloadId is empty")
        }
        let directory = baseDirectory.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BrowserTextPayload(id: id, handoff: handoff))
            .write(to: payloadURL(payloadID: id), options: [.atomic])
    }

    public func handoff(payloadID: String) throws -> BrowserTextHandoff {
        let payloadID = payloadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payloadID.isEmpty else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("payloadId is empty")
        }
        let url = payloadURL(payloadID: payloadID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw Gate5BrowserTextHandoffStoreError.missingPayload(payloadID)
        }
        let payload = try JSONDecoder().decode(BrowserTextPayload.self, from: try Data(contentsOf: url))
        return try payload.handoff(expectedID: payloadID)
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
                return lhsDate == rhsDate ? lhs.lastPathComponent < rhs.lastPathComponent : lhsDate < rhsDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    public func deletePayload(payloadID: String) throws {
        let url = payloadURL(payloadID: payloadID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func quarantine(payloadID: String, reason: String) throws {
        let failed = FailedBrowserTextHandoff(
            id: payloadID,
            handoff: try handoff(payloadID: payloadID),
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            failedAt: Date()
        )
        let directory = baseDirectory.appendingPathComponent(Self.failedPayloadDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = failedPayloadURL(payloadID: payloadID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(failed).write(to: url, options: [.atomic])
        try deletePayload(payloadID: payloadID)
    }

    public func failedHandoffs() throws -> [FailedBrowserTextHandoff] {
        let directory = baseDirectory.appendingPathComponent(Self.failedPayloadDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                try? JSONDecoder().decode(FailedBrowserTextHandoff.self, from: Data(contentsOf: url))
            }
            .sorted { $0.failedAt < $1.failedAt }
    }

    public func retryFailed(payloadID: String) throws {
        let url = failedPayloadURL(payloadID: payloadID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw Gate5BrowserTextHandoffStoreError.missingPayload(payloadID)
        }
        let failed = try JSONDecoder().decode(FailedBrowserTextHandoff.self, from: Data(contentsOf: url))
        let directory = baseDirectory.appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = BrowserTextPayload(id: payloadID, handoff: failed.handoff)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: payloadURL(payloadID: payloadID), options: [.atomic])
        try deleteFailed(payloadID: payloadID)
    }

    public func deleteFailed(payloadID: String) throws {
        try? fileManager.removeItem(at: failedPayloadURL(payloadID: payloadID))
    }

    private func payloadURL(payloadID: String) -> URL {
        baseDirectory
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(payloadID)
            .appendingPathExtension("json")
    }

    private func failedPayloadURL(payloadID: String) -> URL {
        baseDirectory
            .appendingPathComponent(Self.failedPayloadDirectoryName, isDirectory: true)
            .appendingPathComponent(payloadID)
            .appendingPathExtension("json")
    }
}

public struct FailedBrowserTextHandoff: Codable, Equatable, Identifiable {
    public var id: String
    public var handoff: BrowserTextHandoff
    public var reason: String
    public var failedAt: Date

    public init(id: String, handoff: BrowserTextHandoff, reason: String, failedAt: Date) {
        self.id = id
        self.handoff = handoff
        self.reason = reason
        self.failedAt = failedAt
    }
}

private struct BrowserTextPayload: Codable {
    var id: String?
    var itemId: String?
    var captureMode: BrowserTextCaptureMode?
    var contentFormat: BrowserTextContentFormat?
    var source: BrowserTextSource
    var text: String
    var selection: BrowserTextSelection?
    var requestedContinuation: BrowserTextContinuation?

    init(id: String, handoff: BrowserTextHandoff) {
        self.id = id
        itemId = handoff.itemId
        captureMode = handoff.captureMode
        contentFormat = handoff.contentFormat
        source = handoff.source
        text = handoff.text
        selection = handoff.selection
        requestedContinuation = handoff.requestedContinuation
    }

    func handoff(expectedID: String) throws -> BrowserTextHandoff {
        if let id, id != expectedID {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("payload id does not match payloadId")
        }
        guard let captureMode else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("captureMode is required")
        }
        guard !source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("source.url is required")
        }
        guard !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("source.title is required")
        }
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else {
            throw Gate5BrowserTextHandoffStoreError.invalidPayload("text is required")
        }
        return BrowserTextHandoff(
            itemId: itemId,
            captureMode: captureMode,
            source: source,
            text: cleanedText,
            contentFormat: contentFormat,
            selection: selection,
            requestedContinuation: requestedContinuation ?? BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }
}
