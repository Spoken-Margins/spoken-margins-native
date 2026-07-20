import Foundation
import SessionKit

enum Gate5BrowserTextHandoffStoreError: Error, Equatable, LocalizedError {
    case appGroupUnavailable(String)
    case missingPayload(String)
    case invalidPayload(String)

    var errorDescription: String? {
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

struct Gate5BrowserTextHandoffStore {
    static let appGroupIdentifier = "group.com.spokenmargins.native"
    private static let payloadDirectoryName = "BrowserTextHandoffs"
    private static let failedPayloadDirectoryName = "FailedBrowserTextHandoffs"

    private let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    static func appGroup(fileManager: FileManager = .default) throws -> Gate5BrowserTextHandoffStore {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw Gate5BrowserTextHandoffStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        return Gate5BrowserTextHandoffStore(baseDirectory: containerURL, fileManager: fileManager)
    }

    func save(_ handoff: BrowserTextHandoff, payloadID: String) throws {
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

    func handoff(payloadID: String) throws -> BrowserTextHandoff {
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

    func pendingPayloadIDs() throws -> [String] {
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

    func deletePayload(payloadID: String) throws {
        let url = payloadURL(payloadID: payloadID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func quarantine(payloadID: String, reason: String) throws {
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

    func failedHandoffs() throws -> [FailedBrowserTextHandoff] {
        let directory = baseDirectory.appendingPathComponent(Self.failedPayloadDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                try? JSONDecoder().decode(FailedBrowserTextHandoff.self, from: Data(contentsOf: url))
            }
            .sorted { $0.failedAt < $1.failedAt }
    }

    func retryFailed(payloadID: String) throws {
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

    func deleteFailed(payloadID: String) throws {
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

struct FailedBrowserTextHandoff: Codable, Equatable, Identifiable {
    var id: String
    var handoff: BrowserTextHandoff
    var reason: String
    var failedAt: Date
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
