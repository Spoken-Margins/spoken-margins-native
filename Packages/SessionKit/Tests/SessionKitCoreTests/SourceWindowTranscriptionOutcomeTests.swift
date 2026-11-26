import XCTest
@testable import SessionKit

/// The audit on #5124 (`e1eeb7c`, finding 1): a streamed episode's source-window transcription that met the Speech
/// Recognition hold deleted the heard audio and marked the Margin unavailable, so the retry Allow ran found nothing.
final class SourceWindowTranscriptionOutcomeTests: XCTestCase {
    func testTheHoldWaitsForTheAnswerAndKeepsTheAudioTable() {
        typealias Row = (name: String, hasWords: Bool, held: Bool, outcome: SourceWindowTranscriptionOutcome, keepsAudio: Bool)
        let rows: [Row] = [
            ("every piece held", false, true, .waitingForAnswer, true),
            ("one piece held, another gave words: the retry does the whole window", true, true, .waitingForAnswer, true),
            ("a real failure or no speech", false, false, .unavailable, false),
            ("words came back", true, false, .completed, false),
        ]
        for row in rows {
            let outcome = SourceWindowTranscriptionOutcome(hasWords: row.hasWords, held: row.held)
            XCTAssertEqual(outcome, row.outcome, row.name)
            XCTAssertEqual(outcome.keepsAudio, row.keepsAudio, row.name)
        }
    }
}
