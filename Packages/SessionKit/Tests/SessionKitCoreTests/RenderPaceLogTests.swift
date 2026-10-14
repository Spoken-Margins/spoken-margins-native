import Foundation
import XCTest
@testable import SessionKit

/// #540: the owner's phone stalled in Low Power Mode and nobody could say whether rendering had fallen behind
/// playback, because no render time was kept. These pin what is kept and how it reads in the export.
final class RenderPaceLogTests: XCTestCase {
    private func sample(
        at offset: Int = 0,
        render: TimeInterval,
        audio: TimeInterval,
        rate: Double = 0.88,
        lowPower: Bool = false,
        thermal: SpeechThermalLevel = .nominal
    ) -> RenderPaceLog.Sample {
        RenderPaceLog.Sample(
            chunkStartOffset: offset, renderSeconds: render, audioSeconds: audio, playbackRate: rate,
            isLowPowerModeEnabled: lowPower, thermal: thermal
        )
    }

    func testAnEmptyLogSaysNothingWasRendered() {
        XCTAssertEqual(RenderPaceLog().summary, "no chunks rendered")
    }

    func testAChunkThatRendersFasterThanItPlaysKeepsUp() {
        XCTAssertTrue(sample(render: 5, audio: 12).keepsUpWithPlayback)
        XCTAssertEqual(sample(render: 5, audio: 12).audioPerRenderSecond, 2.4, accuracy: 0.0001)
    }

    func testAChunkThatRendersSlowerThanTheListenerUsesItFallsBehind() {
        XCTAssertFalse(sample(render: 18.4, audio: 11.4).keepsUpWithPlayback)
        XCTAssertFalse(sample(render: 10, audio: 10, rate: 1.75).keepsUpWithPlayback, "a faster listener needs a faster renderer")
        XCTAssertTrue(sample(render: 10, audio: 10, rate: 1).keepsUpWithPlayback, "exactly real time holds the buffer steady")
    }

    func testTheLogKeepsTheSlowestChunkAndWhatWasTrueThen() {
        var log = RenderPaceLog()
        log.record(sample(at: 100, render: 4, audio: 12))
        log.record(sample(at: 4210, render: 18.4, audio: 11.4, lowPower: true, thermal: .fair))
        log.record(sample(at: 900, render: 5, audio: 10))

        XCTAssertEqual(log.count, 3)
        XCTAssertEqual(log.behindCount, 1)
        XCTAssertEqual(log.slowest?.chunkStartOffset, 4210)
        XCTAssertEqual(log.latest?.chunkStartOffset, 900)
        XCTAssertEqual(
            log.summary,
            "3 chunks, 1 behind playback; slowest 0.62x (11.4 s of audio in 18.4 s, playing at 0.88x, at 4210, "
                + "Low Power Mode on, thermal fair); latest 2.00x"
        )
    }

    func testAChunkWithNoRenderTimeOrNoAudioSaysNothingAboutPace() {
        var log = RenderPaceLog()
        // Recovered from disk or from prepared audio: nothing was rendered.
        XCTAssertFalse(log.record(sample(render: 0, audio: 9)))
        XCTAssertFalse(log.record(sample(render: 3, audio: 0)))
        XCTAssertFalse(log.record(sample(render: -1, audio: 9)))
        XCTAssertFalse(log.record(sample(render: .infinity, audio: 9)))
        XCTAssertFalse(log.record(sample(render: 3, audio: .nan)))
        XCTAssertEqual(log.count, 0)
        XCTAssertNil(log.slowest)
        XCTAssertEqual(log.summary, "no chunks rendered")
    }

    func testTheFirstOfTwoEquallySlowChunksIsKept() {
        var log = RenderPaceLog()
        log.record(sample(at: 1, render: 10, audio: 5))
        log.record(sample(at: 2, render: 20, audio: 10))
        XCTAssertEqual(log.slowest?.chunkStartOffset, 1)
    }
}
