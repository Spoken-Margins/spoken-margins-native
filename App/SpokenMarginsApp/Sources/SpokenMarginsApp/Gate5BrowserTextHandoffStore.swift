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

    func deletePayload(payloadID: String) throws {
        let url = payloadURL(payloadID: payloadID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func payloadURL(payloadID: String) -> URL {
        baseDirectory
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(payloadID)
            .appendingPathExtension("json")
    }
}

private struct BrowserTextPayload: Decodable {
    var id: String?
    var itemId: String?
    var captureMode: BrowserTextCaptureMode?
    var source: BrowserTextSource
    var text: String
    var selection: BrowserTextSelection?
    var requestedContinuation: BrowserTextContinuation?

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
            selection: selection,
            requestedContinuation: requestedContinuation ?? BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "app")
        )
    }
}
