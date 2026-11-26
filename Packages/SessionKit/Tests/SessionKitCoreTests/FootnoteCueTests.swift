import Foundation
import XCTest
@testable import SessionKit

/// #3777 PR 3: the single tone that marks a cited footnote in "Chime where cited" mode. It must be one soft
/// note that starts gently, is as loud as the friend chime and not louder, and can't be mistaken for it.
final class FootnoteCueTests: XCTestCase {
    private func samples(_ wav: Data) -> [Int16] {
        let payload = wav.dropFirst(44)
        return stride(from: 0, to: payload.count - 1, by: 2).map { offset in
            let low = UInt16(payload[payload.startIndex + offset])
            let high = UInt16(payload[payload.startIndex + offset + 1])
            return Int16(bitPattern: low | high << 8)
        }
    }

    /// The loudest sample in each 5 ms window: the cue's outline.
    private func outline(_ values: [Int16]) -> [Int] {
        let window = FootnoteCue.sampleRate / 200
        return stride(from: 0, to: values.count, by: window).map { start in
            values[start..<min(values.count, start + window)].map { abs(Int($0)) }.max() ?? 0
        }
    }

    func testItIsAPlayable16BitMonoWAVOfTheLengthItClaims() {
        let data = FootnoteCue.wavData()
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(8), as: UTF8.self), "WAVEfmt ")
        func field(_ offset: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        XCTAssertEqual(field(20, 2), 1, "PCM")
        XCTAssertEqual(field(22, 2), 1, "mono")
        XCTAssertEqual(field(24, 4), FootnoteCue.sampleRate)
        XCTAssertEqual(field(34, 2), 16, "16-bit")
        XCTAssertEqual(field(40, 4), data.count - 44, "data length")
        let count = Int(Double(FootnoteCue.sampleRate) * FootnoteCue.seconds)
        XCTAssertEqual(count, 7_938)
        XCTAssertEqual(data.count, 44 + 2 * count)
        XCTAssertEqual(samples(data).count, count)
        XCTAssertEqual(FootnoteCue.seconds, 0.18, accuracy: 0.0001, "the Design's 180 ms")
    }

    func testItIsOneNoteThatRisesOnceAndThenOnlyFades() throws {
        let values = samples(FootnoteCue.wavData())
        let shape = outline(values)
        let top = try XCTUnwrap(shape.max())
        let peakIndex = try XCTUnwrap(shape.firstIndex(of: top))
        // One onset: no window before the peak is louder than the one after it, within a note's own ripple.
        for pair in zip(shape[...peakIndex], shape[...peakIndex].dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1 + top / 20, "rises to the peak")
        }
        for pair in zip(shape[peakIndex...], shape[peakIndex...].dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1, pair.0 + top / 20, "only fades after the peak")
        }
        // No gap inside it: a second onset would need silence first.
        XCTAssertGreaterThan(try XCTUnwrap(shape.dropLast().min()), 0)
        XCTAssertEqual(values.first, 0)
        XCTAssertLessThan(abs(Int(try XCTUnwrap(values.last))), Int(Int16.max) / 200, "ends in silence, no click")
    }

    func testItStartsSoftly() {
        let values = samples(FootnoteCue.wavData())
        // The first millisecond is far below the peak: no sudden onset.
        let firstMillisecond = values.prefix(FootnoteCue.sampleRate / 1_000).map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThan(firstMillisecond, Int(Double(Int16.max) * FootnoteCue.peak) / 5)
    }

    func testItIsNoLouderThanTheFriendChime() throws {
        let cue = samples(FootnoteCue.wavData()).map { abs(Int($0)) }.max() ?? 0
        let chime = samples(SharedMarginCue.doubleChimeWAVData()).map { abs(Int($0)) }.max() ?? 0
        XCTAssertEqual(FootnoteCue.peak, 0.30, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(cue, chime + chime / 100, "within 1% of the chime's peak, rounding aside")
        XCTAssertGreaterThan(cue, Int(Double(chime) * 0.9), "and not much quieter")
    }

    func testItIsE5NotTheFriendChimesNotes() {
        let values = samples(FootnoteCue.wavData())
        let crossings = zip(values, values.dropFirst()).filter { ($0 < 0) != ($1 < 0) && $1 != 0 }.count
        let hertz = Double(crossings) / 2 / FootnoteCue.seconds
        XCTAssertEqual(hertz, 659.25, accuracy: 15)
        XCTAssertEqual(FootnoteCue.frequency, 659.25, accuracy: 0.001)
    }

    func testTheNarrationWaitsLongerThanTheToneAndAboutTheDesignsFortyHundredths() {
        XCTAssertEqual(FootnoteCue.leadIn, 0.4, accuracy: 0.0001, "the Design's pause of about 0.4 s")
        XCTAssertGreaterThan(FootnoteCue.leadIn, FootnoteCue.seconds, "the passage after the note never starts on top of the tone")
    }
}
