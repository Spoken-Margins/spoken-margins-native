import Foundation
import SessionKit

struct ListeningEditionStore {
    let directory: URL
    static func application() throws -> Self {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(directory: root.appendingPathComponent("SpokenMargins/ListeningEditions"))
    }
    func load(itemID: String) throws -> ListeningEdition? {
        let url = file(itemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ListeningEdition.decode(Data(contentsOf: url))
    }
    func save(_ edition: ListeningEdition) throws {
        _ = try edition.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try edition.encoded().write(to: file(edition.itemID), options: .atomic)
    }
    func file(_ itemID: String) -> URL {
        directory.appendingPathComponent(ListeningEdition.digest(itemID)).appendingPathExtension("json")
    }
    static func stage(_ edition: ListeningEdition) throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Gate5BrowserTextHandoffStore.appGroupIdentifier) else {
            throw EditionError.invalid("The shared import folder is unavailable.")
        }
        let directory = root.appendingPathComponent("ListeningEditionInbox")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(edition.itemID).appendingPathExtension("json")
        try edition.encoded().write(to: url, options: .atomic)
        return URL(string: "spokenmargins://listening-edition?id=\(edition.itemID)")!
    }
    static func stagedFile(id: String) throws -> URL {
        guard id.hasPrefix("edition-"), id.count == 72,
              id.dropFirst(8).allSatisfy({ $0.isHexDigit }),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Gate5BrowserTextHandoffStore.appGroupIdentifier) else {
            throw EditionError.invalid("Invalid listening edition handoff.")
        }
        return root.appendingPathComponent("ListeningEditionInbox/\(id).json")
    }
}
