import Foundation
import XCTest
@testable import SessionKit

/// #731: the meter and the renderer take a recording in chunks, so a long Margin is never in memory
/// at once, and the answer doesn't depend on how it was cut up.
final class ChunkedLoudnessTests: XCTestCase {
    func testMeasuringInChunksGivesTheSameMeasurementAsMeasuringAtOnce() {
        let recording = Self.peakyStereo(seconds: 2.5)
        let atOnce = LoudnessMeter.measure(channels: recording, sampleRate: 48_000)
        XCTAssertNotNil(atOnce.integratedLUFS)
        for chunkFrames in [1, 7, 1_000, 19_201] {
            var meter = LoudnessMeter.Accumulator(channelCount: 2, sampleRate: 48_000)
            for chunk in Self.chunks(of: recording, frames: chunkFrames) { meter.add(chunk) }
            XCTAssertEqual(meter.finish(), atOnce, "chunks of \(chunkFrames)")
        }
    }

    func testShortRecordingsMeasureTheSameInChunks() {
        // Shorter than one 400 ms block and than one 50 ms window, which are measured whole.
        for frames in [0, 1, 1_000, 5_000] {
            let recording = Array(Self.peakyStereo(seconds: 1).map { Array($0.prefix(frames)) })
            let atOnce = LoudnessMeter.measure(channels: recording, sampleRate: 48_000)
            var meter = LoudnessMeter.Accumulator(channelCount: 2, sampleRate: 48_000)
            for chunk in Self.chunks(of: recording, frames: 7) { meter.add(chunk) }
            XCTAssertEqual(meter.finish(), atOnce, "\(frames) frames")
        }
    }

    func testRenderingInChunksGivesTheSameSamplesAsRenderingAtOnce() {
        let recording = Self.peakyStereo(seconds: 1.5)
        let plan = LoudnessLeveling.plan(LoudnessMeter.measure(channels: recording, sampleRate: 48_000))
        XCTAssertGreaterThan(plan.limiterReductionDB, 1, "the limiter has work to do")
        var whole = LoudnessLeveling.Renderer(channelCount: 2, gainDB: plan.gainDB)
        let atOnce = Self.concatenate(whole.process(recording), whole.finish())
        XCTAssertEqual(atOnce[0].count, recording[0].count)
        for chunkFrames in [1, 7, 1_000] {
            var renderer = LoudnessLeveling.Renderer(channelCount: 2, gainDB: plan.gainDB)
            var output: [[Float]] = [[], []]
            for chunk in Self.chunks(of: recording, frames: chunkFrames) { output = Self.concatenate(output, renderer.process(chunk)) }
            output = Self.concatenate(output, renderer.finish())
            XCTAssertEqual(output, atOnce, "chunks of \(chunkFrames)")
        }
    }

    func testTheStreamingLimiterMatchesTheWholeRecordingLimiterItReplaced() {
        for (name, recording, gainDB) in [
            ("peaky stereo, limited", Self.peakyStereo(seconds: 1.5), 14.0),
            ("quiet mono, untouched", [LoudnessTests.speechLike(seconds: 1, noiseDBFS: -80, seed: 9, speechDBFS: -40)], 6.0),
            ("shorter than the look-ahead", Self.peakyStereo(seconds: 1).map { Array($0[9_990..<10_200]) }, 20.0),
        ] {
            let reference = ReferenceLimiter.render(channels: recording, gainDB: gainDB)
            XCTAssertEqual(LoudnessLeveling.render(channels: recording, gainDB: gainDB), reference, name)
        }
    }

    func testTheRendererHoldsOnlyItsLookAheadNotTheRecording() {
        let recording = Self.peakyStereo(seconds: 2)
        var renderer = LoudnessLeveling.Renderer(channelCount: 2, gainDB: 12)
        var returned = 0
        for chunk in Self.chunks(of: recording, frames: 4_096) {
            returned += renderer.process(chunk)[0].count
            XCTAssertLessThanOrEqual(renderer.bufferedFrames, LoudnessLeveling.Renderer.lookAheadFrames)
        }
        returned += renderer.finish()[0].count
        XCTAssertEqual(returned, recording[0].count, "every frame comes out once")
        XCTAssertEqual(renderer.bufferedFrames, 0)
        XCTAssertLessThan(LoudnessLeveling.Renderer.lookAheadFrames, 48_000 / 50, "under 20 ms of audio")
    }

    // MARK: Helpers

    /// Speech-like stereo with sharp clicks, quiet enough that leveling boosts it into the limiter.
    static func peakyStereo(seconds: Double) -> [[Float]] {
        var left = LoudnessTests.scaled(LoudnessTests.speechLike(seconds: seconds, noiseDBFS: -90, seed: 11), toLUFS: -30)
        let right = LoudnessTests.scaled(LoudnessTests.speechLike(seconds: seconds, noiseDBFS: -90, seed: 12), toLUFS: -32)
        for click in stride(from: 10_000, to: left.count - 1, by: 30_000) {
            left[click] = 0.3
            left[click + 1] = -0.3
        }
        return [left, right]
    }

    static func chunks(of channels: [[Float]], frames: Int) -> [[[Float]]] {
        let count = channels.first?.count ?? 0
        return stride(from: 0, to: count, by: frames).map { start in
            channels.map { Array($0[start..<min(count, start + frames)]) }
        }
    }

    static func concatenate(_ first: [[Float]], _ second: [[Float]]) -> [[Float]] {
        zip(first, second).map { $0 + $1 }
    }
}

/// The whole-recording gain, limiter and trim that `LoudnessLeveling.render` used before #731,
/// copied unchanged (with its oversampler) as the reference for the streaming one.
private enum ReferenceLimiter {
    static func render(channels: [[Float]], gainDB: Double) -> [[Float]] {
        let gain = Float(pow(10, gainDB / 20))
        var output = channels.map { $0.map { $0 * gain } }
        limit(&output, ceiling: pow(10, (LoudnessLeveling.truePeakCeilingDBTP - 0.3) / 20))
        let peak = output.map { channel -> Double in
            let sampled = channel.reduce(0.0) { max($0, abs(Double($1))) }
            return max(sampled, interpolatedPeaks(channel).max() ?? 0)
        }.max() ?? 0
        let peakDB = LoudnessMeter.decibels(amplitude: peak)
        if peakDB > LoudnessLeveling.truePeakCeilingDBTP {
            let trim = Float(pow(10, (LoudnessLeveling.truePeakCeilingDBTP - peakDB) / 20))
            output = output.map { $0.map { $0 * trim } }
        }
        return output
    }

    static func limit(_ channels: inout [[Float]], ceiling: Double) {
        guard let length = channels.first?.count, length > 0 else { return }
        var needed = [Double](repeating: 1, count: length)
        for channel in channels {
            let envelope = oversampledEnvelope(channel)
            for i in 0..<length where envelope[i] > ceiling {
                needed[i] = min(needed[i], ceiling / envelope[i])
            }
        }
        guard needed.contains(where: { $0 < 1 }) else { return }
        let radius = max(1, Int(0.005 * 48_000.0))
        let held = slidingMinimum(needed, radius: radius)
        let smoothed = movingAverage(held, radius: radius)
        let release = exp(-1 / (0.08 * 48_000.0))
        var gain = 1.0
        var envelope = [Double](repeating: 1, count: length)
        for i in 0..<length {
            gain = min(smoothed[i], release * gain + (1 - release))
            envelope[i] = gain
        }
        for c in channels.indices {
            for i in channels[c].indices { channels[c][i] *= Float(envelope[i]) }
        }
    }

    static func oversampledEnvelope(_ samples: [Float]) -> [Double] {
        var envelope = samples.map { abs(Double($0)) }
        let delay = TruePeakOversampler.tapsPerPhase / 2
        for (n, peak) in interpolatedPeaks(samples).enumerated() {
            for target in [n - delay, n - delay + 1] where target >= 0 && target < envelope.count {
                envelope[target] = max(envelope[target], peak)
            }
        }
        return envelope
    }

    static func interpolatedPeaks(_ samples: [Float]) -> [Double] {
        let count = samples.count
        let taps = TruePeakOversampler.tapsPerPhase
        let coefficients = TruePeakOversampler.phases.flatMap { $0 }
        var peaks = [Double](repeating: 0, count: count + taps)
        samples.withUnsafeBufferPointer { xBuffer in
            coefficients.withUnsafeBufferPointer { hBuffer in
                peaks.withUnsafeMutableBufferPointer { outBuffer in
                    guard let x = xBuffer.baseAddress, let h = hBuffer.baseAddress, let out = outBuffer.baseAddress else { return }
                    var n = 0
                    while n < count + taps {
                        let low = n - count + 1 > 0 ? n - count + 1 : 0
                        let high = n < taps - 1 ? n : taps - 1
                        var peak = 0.0
                        var phase = 0
                        while phase < TruePeakOversampler.factor {
                            var value = 0.0
                            let row = h + phase * taps
                            var m = low
                            while m <= high {
                                value += row[m] * Double(x[n - m])
                                m += 1
                            }
                            peak = max(peak, abs(value))
                            phase += 1
                        }
                        out[n] = peak
                        n += 1
                    }
                }
            }
        }
        return peaks
    }

    static func slidingMinimum(_ values: [Double], radius: Int) -> [Double] {
        var result = [Double](repeating: 1, count: values.count)
        var deque: [Int] = []
        var head = 0
        var next = 0
        for i in 0..<values.count {
            while next < values.count && next <= i + radius {
                while deque.count > head && values[deque[deque.count - 1]] >= values[next] { deque.removeLast() }
                deque.append(next)
                next += 1
            }
            while deque[head] < i - radius { head += 1 }
            result[i] = values[deque[head]]
        }
        return result
    }

    static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { prefix[i + 1] = prefix[i] + values[i] }
        return values.indices.map { i in
            let low = max(0, i - radius), high = min(values.count - 1, i + radius)
            return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
        }
    }
}
