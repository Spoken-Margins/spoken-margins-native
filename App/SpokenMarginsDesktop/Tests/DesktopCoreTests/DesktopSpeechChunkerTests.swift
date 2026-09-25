import XCTest
@testable import DesktopCore

final class DesktopSpeechChunkerTests: XCTestCase {
    func testChunksPreserveUnicodeSourceRangesAndNaturalBoundaries() {
        let source = "🙂 First sentence.\n" + String(repeating: "A sentence with an emoji 🧭 and stable source offsets. ", count: 12)
        let chunks = DesktopSpeechChunker.chunks(in: source, from: 0)
        let characters = Array(source)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end, characters.count)
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty && $0.sourceRange.count <= 180 })
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.0.end, pair.1.start)
        }
        for chunk in chunks {
            XCTAssertEqual(String(characters[chunk.sourceRange]).trimmingCharacters(in: .whitespacesAndNewlines), chunk.text)
        }
    }

    func testChunkingStartsAtRequestedCharacterOffsetAndClampsPastEnd() {
        let source = "A🙂B. " + String(repeating: "more words and punctuation. ", count: 10)
        let offset = 2
        let chunks = DesktopSpeechChunker.chunks(in: source, from: offset)

        XCTAssertEqual(chunks.first?.start, offset)
        XCTAssertEqual(chunks.last?.end, source.count)
        XCTAssertTrue(DesktopSpeechChunker.chunks(in: source, from: source.count + 10).isEmpty)
    }
}
