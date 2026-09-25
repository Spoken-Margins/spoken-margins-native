import CryptoKit
import Foundation

/// Summaries are local derived data. A source digest prevents showing stale AI
/// text if an item is ever replaced while retaining its identifier.
public final class DesktopChapterSummaryStore {
    private struct Record: Codable {
        let sourceDigest: String
        let summaries: [String: String]
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(itemID: String, sourceText: String) -> [String: String] {
        guard let data = try? Data(contentsOf: url(for: itemID)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.sourceDigest == digest(sourceText) else { return [:] }
        return record.summaries
    }

    public func save(_ summaries: [String: String], itemID: String, sourceText: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Record(sourceDigest: digest(sourceText), summaries: summaries)
        try JSONEncoder().encode(record).write(to: url(for: itemID), options: .atomic)
    }

    private func url(for itemID: String) -> URL {
        directory.appendingPathComponent(digest(itemID) + ".json")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
