import Foundation
import XCTest
@testable import SessionKit

/// The endings of a spoken Margin each sound different, and none runs on (#1977).
final class MarginOutcomeCueTests: XCTestCase {
    func testEveryVerdictHasItsOwnCue() {
        XCTAssertEqual(MarginOutcomeCue(verdict: .save), .saved)
        XCTAssertEqual(MarginOutcomeCue(verdict: .saveCutShort), .savedMaybeCut)
        XCTAssertEqual(MarginOutcomeCue(verdict: .discardEmpty), .emptyDiscarded)
        XCTAssertEqual(Set(MarginCaptureSupervisor.SaveVerdict.allCasesForTest.map { MarginOutcomeCue(verdict: $0) }).count, 3)
    }

    func testTheFourSoundsAllDiffer() {
        let waves = MarginOutcomeCue.allCases.map { $0.wavData() }
        XCTAssertEqual(Set(waves).count, MarginOutcomeCue.allCases.count, "two endings must never sound alike")
    }

    func testNoSoundRunsLongerThanTheLimitAndEachCarriesAudio() throws {
        for cue in MarginOutcomeCue.allCases {
            XCTAssertLessThan(cue.soundSeconds, MarginOutcomeCue.maxSoundSeconds, "\(cue)")
            let data = cue.wavData()
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            let samples = stride(from: 44, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
            XCTAssertGreaterThan(samples.map { abs(Int($0)) }.max() ?? 0, 3_000, "\(cue) is not silent")
            XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, 12_000, "\(cue) stays soft")
            let seconds = Double(samples.count) / Double(MarginOutcomeCue.sampleRate)
            if cue.repeats {
                XCTAssertEqual(seconds, MarginOutcomeCue.micStoppedPeriod, accuracy: 0.01, "a repeating cue is a whole period")
            } else {
                XCTAssertEqual(seconds, cue.soundSeconds, accuracy: 0.01, "a one-shot cue has no padding")
            }
        }
    }

    func testOnlyTheDeadMicrophoneRepeats() {
        XCTAssertEqual(MarginOutcomeCue.allCases.filter(\.repeats), [.micStopped])
    }
}

private extension MarginCaptureSupervisor.SaveVerdict {
    static var allCasesForTest: [Self] { [.save, .saveCutShort, .discardEmpty] }
}
