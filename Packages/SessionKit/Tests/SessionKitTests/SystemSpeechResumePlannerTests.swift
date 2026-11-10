import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #2256: the live system-voice planner takes the tail of the memoised projection when a play resumes from a saved
/// offset. The projection itself is tested in SessionKitCoreTests (`SystemSpeechResumeProjectionTests`).
final class SystemSpeechResumePlannerTests: XCTestCase {
    override func setUp() { SpeechTextNormalizer.projectionMemo.forget() }
    override func tearDown() { SpeechTextNormalizer.projectionMemo.forget() }

    private func article() -> String {
        String(repeating: "Paragraph opens <b>here</b> and cites [the study](https://example.com/a/b) before it ends. Two  spaces and more words to read aloud.\n\n", count: 300)
    }

    func testAResumeDoesNotProjectTheRemainingTextAgain() {
        let text = article()
        XCTAssertGreaterThan(text.utf8.count, SpeechProjectionMemo.minimumBytes)
        SpeechTextNormalizer.prewarm(text, kinds: .system)
        let offset = text.count / 2
        let remaining = String(Array(text)[offset...])
        XCTAssertGreaterThan(remaining.utf8.count, SpeechProjectionMemo.minimumBytes)

        let chunks = SpeechPlaybackPlanner.chunks(in: text, from: offset)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertFalse(SpeechTextNormalizer.projectionMemo.remembers(remaining, kind: .systemSpeech))
        XCTAssertGreaterThanOrEqual(chunks[0].sourceStart, offset)
        XCTAssertEqual(chunks.last?.sourceEnd, text.count)
        XCTAssertTrue(zip(chunks, chunks.dropFirst()).allSatisfy { $0.sourceEnd == $1.sourceStart })
    }

    func testAResumeAtTheEndOrPastItHasNothingToSay() {
        let text = article()
        XCTAssertTrue(SpeechPlaybackPlanner.chunks(in: text, from: text.count).isEmpty)
        XCTAssertTrue(SpeechPlaybackPlanner.chunks(in: text, from: text.count + 10).isEmpty)
    }
}
