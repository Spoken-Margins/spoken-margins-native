import Foundation

/// A generated audio chunk tied to the exact source-character range it speaks.
public struct DesktopSpeechChunk: Sendable, Equatable {
    public let sourceRange: Range<Int>
    public let text: String

    public var start: Int { sourceRange.lowerBound }
    public var end: Int { sourceRange.upperBound }

    fileprivate init(sourceRange: Range<Int>, text: String) {
        self.sourceRange = sourceRange
        self.text = text
    }
}

public enum DesktopSpeechChunker {
    /// Splits at sentence or word boundaries while keeping offsets in Swift
    /// character positions, matching the desktop session's persisted offsets.
    public static func chunks(in source: String, from offset: Int) -> [DesktopSpeechChunk] {
        let characters = Array(source)
        var cursor = max(0, min(offset, characters.count))
        var result: [DesktopSpeechChunk] = []

        while cursor < characters.count {
            let hardEnd = min(characters.count, cursor + 180)
            var end = hardEnd
            if hardEnd < characters.count,
               let boundary = (cursor..<hardEnd).reversed().first(where: {
                   ".!?;:\n".contains(characters[$0]) && $0 >= cursor + 48
               }) {
                end = boundary + 1
            } else if hardEnd < characters.count,
                      let space = (cursor..<hardEnd).reversed().first(where: {
                          characters[$0].isWhitespace && $0 >= cursor + 60
                      }) {
                end = space + 1
            }

            let text = String(characters[cursor..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(DesktopSpeechChunk(sourceRange: cursor..<end, text: text))
            }
            cursor = end
        }

        return result
    }
}
