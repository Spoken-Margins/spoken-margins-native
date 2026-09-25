import Foundation
import SessionKit

public enum DesktopBrowserInboxError: Error, LocalizedError {
    case invalidURL
    case invalidPayload
    case missingPayload

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The browser handoff URL is invalid."
        case .invalidPayload: "The browser capture is invalid or too large."
        case .missingPayload: "The browser capture could not be found."
        }
    }
}

public struct DesktopBrowserInbox {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func payloadID(from url: URL) throws -> String {
        guard url.scheme == "spokenmargins-desktop", url.host == "browser-text",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "payloadId" })?.value,
              UUID(uuidString: id) != nil else { throw DesktopBrowserInboxError.invalidURL }
        return id
    }

    public func load(id: String) throws -> BrowserTextHandoff {
        guard UUID(uuidString: id) != nil else { throw DesktopBrowserInboxError.invalidURL }
        let url = directory.appendingPathComponent(id).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw DesktopBrowserInboxError.missingPayload }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000,
              let handoff = try? JSONDecoder().decode(BrowserTextHandoff.self, from: data),
              handoff.schemaVersion == "browser-text-handoff.v1",
              handoff.itemId == nil,
              handoff.text.count <= 100_000,
              let sourceURL = URL(string: handoff.source.url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            throw DesktopBrowserInboxError.invalidPayload
        }
        return handoff
    }

    public func remove(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw DesktopBrowserInboxError.invalidURL }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id).appendingPathExtension("json"))
    }
}
