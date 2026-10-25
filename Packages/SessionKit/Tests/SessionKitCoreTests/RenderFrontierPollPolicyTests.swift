import SessionKit
import XCTest

final class RenderFrontierPollPolicyTests: XCTestCase {
    /// Drives the same loop shape the playback screen uses and counts the reads it makes.
    private func run(passes: Int, signal: PreparedAudioChangeSignal, fractions: [Double], between: (Int) -> Void = { _ in }) -> Int {
        var policy = RenderFrontierPollPolicy()
        var reads = 0
        for pass in 0..<passes {
            between(pass)
            let generation = signal.generation
            guard policy.shouldRead(generation: generation) else { continue }
            let fraction = fractions[min(reads, fractions.count - 1)]
            reads += 1
            policy.record(fraction: fraction, generation: generation)
        }
        return reads
    }

    func testIncompleteRenderKeepsReading() {
        XCTAssertEqual(run(passes: 10, signal: PreparedAudioChangeSignal(), fractions: [0.2, 0.5, 0.9]), 10)
    }

    func testCompleteRenderStopsReading() {
        // 0.5, then 1.0, then nothing for the other eight passes.
        XCTAssertEqual(run(passes: 10, signal: PreparedAudioChangeSignal(), fractions: [0.5, 1.0]), 2)
    }

    func testChangeSignalWakesACompleteRender() {
        let signal = PreparedAudioChangeSignal()
        // Complete at once; the manifest is invalidated at pass 4 and the next read finds it partial.
        let reads = run(passes: 10, signal: signal, fractions: [1.0, 0.3]) { pass in
            if pass == 4 { signal.bump() }
        }
        // read at pass 0 (complete), quiet 1-3, read at 4 (0.3), then every pass 5-9.
        XCTAssertEqual(reads, 2 + 5)
    }

    func testChangeThatLeavesItCompleteGoesQuietAgain() {
        let signal = PreparedAudioChangeSignal()
        let reads = run(passes: 10, signal: signal, fractions: [1.0]) { pass in
            if pass == 4 { signal.bump() }
        }
        XCTAssertEqual(reads, 2)
    }
}
