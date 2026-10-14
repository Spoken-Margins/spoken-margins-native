import Foundation

/// The word list the front end looks pronunciations up in: one `word<TAB>espeak IPA` line per entry,
/// sorted by the word's UTF-8 bytes (`export_for_swift.py` writes it). The file is memory-mapped and
/// searched in place, so its 180,000 entries never become a dictionary in memory.
public final class PronunciationLexicon: Sendable {
    private let data: Data

    public init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    /// The pronunciation stored for exactly this word, or nil.
    public func pronunciation(of word: String) -> String? {
        let key = Array(word.utf8)
        guard !key.isEmpty else { return nil }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
            let newline = UInt8(ascii: "\n"), tab = UInt8(ascii: "\t")
            var low = 0, high = bytes.count                      // [low, high) always starts at a line start
            while low < high {
                let middle = low + (high - low) / 2
                var lineStart = middle
                while lineStart > low, bytes[lineStart - 1] != newline { lineStart -= 1 }
                var lineEnd = middle
                while lineEnd < bytes.count, bytes[lineEnd] != newline { lineEnd += 1 }
                var keyEnd = lineStart
                while keyEnd < lineEnd, bytes[keyEnd] != tab { keyEnd += 1 }
                switch Self.compare(bytes, lineStart..<keyEnd, key) {
                case .orderedSame:
                    guard keyEnd < lineEnd else { return nil }
                    return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(keyEnd + 1)..<lineEnd]), as: UTF8.self)
                case .orderedAscending:                          // the line's word sorts before the key
                    low = lineEnd + 1
                case .orderedDescending:
                    high = lineStart
                }
            }
            return nil
        }
    }

    private static func compare(_ bytes: UnsafeRawBufferPointer, _ range: Range<Int>, _ key: [UInt8]) -> ComparisonResult {
        var index = range.lowerBound, other = 0
        while index < range.upperBound, other < key.count {
            if bytes[index] != key[other] { return bytes[index] < key[other] ? .orderedAscending : .orderedDescending }
            index += 1
            other += 1
        }
        if index == range.upperBound { return other == key.count ? .orderedSame : .orderedAscending }
        return .orderedDescending
    }
}
