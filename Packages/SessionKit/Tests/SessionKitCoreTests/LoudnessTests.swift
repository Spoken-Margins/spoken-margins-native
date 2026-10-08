import Foundation
import XCTest
@testable import SessionKit

/// #465: loudness measurement against the EBU Tech 3341 reference signals, the leveling planner's
/// caps, and rendering generated speech-like recordings to the playback target.
final class LoudnessTests: XCTestCase {
    // MARK: Measurement (BS.1770-4 / EBU Tech 3341)

    func testEBU3341StereoSineAtMinus23AndMinus33ReadsTheSame() {
        for level in [-23.0, -33.0] {
            let sine = Self.sine(frequency: 1_000, amplitudeDB: level, seconds: 5, sampleRate: 48_000)
            let measured = LoudnessMeter.integratedLoudness(channels: [sine, sine], sampleRate: 48_000)
            XCTAssertEqual(measured ?? 0, level, accuracy: 0.1, "EBU Tech 3341 cases 1 and 2")
        }
    }

    func testEBU3341GatingIgnoresTheQuietEnds() {
        // Case 3 (10 s at -36 dBFS, 60 s at -23, 10 s at -36 reads -23.0 LUFS), shortened to 5/20/5 s.
        let quiet = Self.sine(frequency: 1_000, amplitudeDB: -36, seconds: 5, sampleRate: 48_000)
        let loud = Self.sine(frequency: 1_000, amplitudeDB: -23, seconds: 20, sampleRate: 48_000)
        let signal = quiet + loud + quiet
        let measured = LoudnessMeter.integratedLoudness(channels: [signal, signal], sampleRate: 48_000)
        XCTAssertEqual(measured ?? 0, -23, accuracy: 0.1)
    }

    func testFullScaleSineInOneChannelIsMinus3LKFSAtEitherRate() {
        // BS.1770-4: a 0 dB FS 1 kHz sine applied to one channel reads -3.01 LKFS.
        for rate in [44_100.0, 48_000.0] {
            let sine = Self.sine(frequency: 997, amplitudeDB: 0, seconds: 5, sampleRate: rate)
            let measured = LoudnessMeter.integratedLoudness(channels: [sine], sampleRate: rate)
            XCTAssertEqual(measured ?? 0, -3.01, accuracy: 0.1, "\(rate) Hz")
        }
    }

    func testKWeightingAt48kHzHasTheStandardsCoefficients() {
        let stages = KWeighting(sampleRate: 48_000).stages
        let published = [
            [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585],
            [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621],
        ]
        for (stage, expected) in zip(stages, published) {
            for (value, reference) in zip([stage.b0, stage.b1, stage.b2, stage.a1, stage.a2], expected) {
                XCTAssertEqual(value, reference, accuracy: 1e-8)
            }
        }
    }

    func testTruePeakFindsThePeakBetweenSamples() {
        // A quarter-rate sine at 45° is sampled at 0.707 of its peak: -9.03 dBFS sampled, -6.02 dBTP true.
        let samples = (0..<48_000).map { Float(0.5 * sin(Double.pi / 2 * Double($0) + Double.pi / 4)) }
        XCTAssertEqual(LoudnessMeter.decibels(amplitude: Double(samples.map(abs).max()!)), -9.03, accuracy: 0.05)
        XCTAssertEqual(LoudnessMeter.truePeak(channels: [samples]), -6.02, accuracy: 0.3)
    }

    func testSilenceHasNoLoudnessAndFiniteFloors() {
        let silence = [Float](repeating: 0, count: 48_000)
        let measured = LoudnessMeter.measure(channels: [silence], sampleRate: 48_000)
        XCTAssertNil(measured.integratedLUFS)
        XCTAssertEqual(measured.truePeakDBTP, LoudnessMeter.floorDB)
        XCTAssertEqual(measured.noiseFloorDBFS, LoudnessMeter.floorDB)
        XCTAssertEqual(LoudnessLeveling.plan(measured), LoudnessLevelingPlan(gainDB: 0, limit: .silent, limiterReductionDB: 0))
    }

    func testRoomNoiseUnderTheAbsoluteGateHasNoLoudnessButASoftVoiceHas() {
        // Silence reads about -300 LUFS, so it is dropped by any gate. These are the signals the -70 LUFS gate is for:
        // a stereo 1 kHz sine reads its own dBFS in LUFS, so -80 is room noise and -65 is a very quiet voice.
        let noise = Self.sine(frequency: 1_000, amplitudeDB: -80, seconds: 5, sampleRate: 48_000)
        let measuredNoise = LoudnessMeter.measure(channels: [noise, noise], sampleRate: 48_000)
        XCTAssertNil(measuredNoise.integratedLUFS, "-80 dBFS is under the -70 LUFS absolute gate")
        XCTAssertGreaterThan(measuredNoise.truePeakDBTP, LoudnessMeter.floorDB, "it is not digital silence")
        XCTAssertEqual(LoudnessLeveling.plan(measuredNoise), LoudnessLevelingPlan(gainDB: 0, limit: .silent, limiterReductionDB: 0),
                       "room noise is left as it is, not boosted by the maximum")

        let quiet = Self.sine(frequency: 1_000, amplitudeDB: -65, seconds: 5, sampleRate: 48_000)
        let measuredQuiet = LoudnessMeter.measure(channels: [quiet, quiet], sampleRate: 48_000)
        XCTAssertEqual(measuredQuiet.integratedLUFS ?? 0, -65, accuracy: 0.2, "-65 dBFS is over the gate")
        XCTAssertNotEqual(LoudnessLeveling.plan(measuredQuiet).limit, .silent)
    }

    func testNoiseFloorReadsTheQuietStretchesNotTheSpeech() {
        let recording = Self.speechLike(seconds: 8, noiseDBFS: -62, seed: 7)
        let floor = LoudnessMeter.noiseFloor(channels: [recording], sampleRate: 48_000)
        XCTAssertEqual(floor, -62, accuracy: 3)
    }

    // MARK: Planner

    func testPlannerBoostsToTheTargetUpTo18dB() {
        let plan = LoudnessLeveling.plan(.init(integratedLUFS: -30, truePeakDBTP: -18, noiseFloorDBFS: -90))
        XCTAssertEqual(plan.gainDB, 14, accuracy: 1e-9)
        XCTAssertEqual(plan.limit, .target)
        let capped = LoudnessLeveling.plan(.init(integratedLUFS: -45, truePeakDBTP: -33, noiseFloorDBFS: -110))
        XCTAssertEqual(capped.gainDB, LoudnessLeveling.maximumBoostDB)
        XCTAssertEqual(LoudnessLeveling.maximumBoostDB, 18)
        XCTAssertEqual(capped.limit, .maximumBoost)
    }

    func testPlannerCutsAnyAmount() {
        let plan = LoudnessLeveling.plan(.init(integratedLUFS: 0, truePeakDBTP: 0, noiseFloorDBFS: -60))
        XCTAssertEqual(plan.gainDB, -16, accuracy: 1e-9)
        XCTAssertEqual(plan.limiterReductionDB, 0)
    }

    func testPlannerCapsTheBoostWhenTheNoiseFloorIsHigh() {
        XCTAssertEqual(LoudnessLeveling.maximumNoiseFloorAfterGainDBFS, -48)
        let plan = LoudnessLeveling.plan(.init(integratedLUFS: -40, truePeakDBTP: -30, noiseFloorDBFS: -58))
        XCTAssertEqual(plan.gainDB, 10, accuracy: 1e-9, "the noise floor may rise to -48 dBFS and no further")
        XCTAssertEqual(plan.limit, .noiseFloor)
        let noisy = LoudnessLeveling.plan(.init(integratedLUFS: -40, truePeakDBTP: -30, noiseFloorDBFS: -45))
        XCTAssertEqual(noisy.gainDB, 0, "already noisier than the cap: no boost, and no cut either")
        let loudAndNoisy = LoudnessLeveling.plan(.init(integratedLUFS: -10, truePeakDBTP: -2, noiseFloorDBFS: -40))
        XCTAssertEqual(loudAndNoisy.gainDB, -6, accuracy: 1e-9, "the cap never stops a cut")
    }

    func testPlannerKeepsLimitingWithinItsAllowance() {
        XCTAssertEqual(LoudnessLeveling.truePeakCeilingDBTP, -1)
        let plan = LoudnessLeveling.plan(.init(integratedLUFS: -30, truePeakDBTP: -4, noiseFloorDBFS: -90))
        XCTAssertEqual(plan.gainDB, -1 + LoudnessLeveling.maximumLimiterReductionDB + 4, accuracy: 1e-9)
        XCTAssertEqual(plan.limit, .truePeak)
        XCTAssertEqual(plan.limiterReductionDB, LoudnessLeveling.maximumLimiterReductionDB, accuracy: 1e-9)
    }

    // MARK: Rendering generated recordings

    func testARecording20dBUnderTheTargetRendersToItWithPeaksUnderTheCeiling() {
        let input = Self.scaled(Self.speechLike(seconds: 5, noiseDBFS: -85, seed: 1), toLUFS: -36)
        let original = input
        let measured = LoudnessMeter.measure(channels: [input], sampleRate: 48_000)
        let plan = LoudnessLeveling.plan(measured)
        XCTAssertEqual(plan.gainDB, 18, accuracy: 0.01, "20 dB is more than the 18 dB boost allows")
        let output = LoudnessLeveling.render(channels: [input], gainDB: plan.gainDB)
        let result = LoudnessMeter.measure(channels: output, sampleRate: 48_000)
        // 20 dB under with an 18 dB cap lands exactly 2 LU short; allow for rounding.
        XCTAssertEqual(result.integratedLUFS ?? 0, -16, accuracy: 2.01)
        XCTAssertLessThanOrEqual(result.truePeakDBTP, -1)
        XCTAssertEqual(input, original, "the input samples are untouched")
    }

    func testARecording6dBOverTheTargetIsTurnedDown() {
        let input = Self.scaled(Self.speechLike(seconds: 5, noiseDBFS: -85, seed: 2), toLUFS: -10)
        let measured = LoudnessMeter.measure(channels: [input], sampleRate: 48_000)
        let plan = LoudnessLeveling.plan(measured)
        XCTAssertLessThan(plan.gainDB, 0)
        let result = LoudnessMeter.measure(channels: LoudnessLeveling.render(channels: [input], gainDB: plan.gainDB), sampleRate: 48_000)
        XCTAssertEqual(result.integratedLUFS ?? 0, -16, accuracy: 2)
        XCTAssertLessThanOrEqual(result.truePeakDBTP, -1)
    }

    func testANearSilentRecordingIsBoostedLessThanTheFullAmount() {
        // Mostly hiss at -60 dBFS with a few faint words.
        let input = Self.speechLike(seconds: 6, noiseDBFS: -60, seed: 3, speechDBFS: -50, wordsPerSecond: 0.6)
        let measured = LoudnessMeter.measure(channels: [input], sampleRate: 48_000)
        let plan = LoudnessLeveling.plan(measured)
        let full = min(LoudnessLeveling.maximumBoostDB, LoudnessLeveling.defaultTargetLUFS - (measured.integratedLUFS ?? 0))
        XCTAssertLessThan(plan.gainDB, full - 1)
        XCTAssertEqual(plan.limit, .noiseFloor)
        let result = LoudnessMeter.measure(channels: LoudnessLeveling.render(channels: [input], gainDB: plan.gainDB), sampleRate: 48_000)
        XCTAssertLessThanOrEqual(result.noiseFloorDBFS, LoudnessLeveling.maximumNoiseFloorAfterGainDBFS + 0.5)
    }

    func testTheLimiterHoldsTheCeilingOnAPeakyRecording() {
        // Quiet speech with sharp clicks: the plan needs the limiter.
        var input = Self.scaled(Self.speechLike(seconds: 4, noiseDBFS: -90, seed: 4), toLUFS: -30)
        for click in stride(from: 10_000, to: input.count, by: 40_000) {
            input[click] = 0.3
            input[click + 1] = -0.3
        }
        let measured = LoudnessMeter.measure(channels: [input, input], sampleRate: 48_000)
        let plan = LoudnessLeveling.plan(measured)
        XCTAssertGreaterThan(plan.limiterReductionDB, 1)
        let output = LoudnessLeveling.render(channels: [input, input], gainDB: plan.gainDB)
        let result = LoudnessMeter.measure(channels: output, sampleRate: 48_000)
        XCTAssertLessThanOrEqual(result.truePeakDBTP, -1)
        XCTAssertEqual(result.integratedLUFS ?? 0, (measured.integratedLUFS ?? 0) + plan.gainDB, accuracy: 1, "clicks are limited, speech isn't")
    }

    // MARK: Signals

    static func sine(frequency: Double, amplitudeDB: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let amplitude = pow(10, amplitudeDB / 20)
        return (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Syllable-like bursts (voiced harmonics plus breath noise under a smooth envelope) with pauses of
    /// background noise, at 48 kHz. Seeded, so every run is identical.
    static func speechLike(seconds: Double, noiseDBFS: Double, seed: UInt64, speechDBFS: Double = -20, wordsPerSecond: Double = 3.5) -> [Float] {
        let rate = 48_000.0
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let count = Int(seconds * rate)
        // White noise at RMS 1 is uniform in ±sqrt(3).
        let noiseAmplitude = pow(10, noiseDBFS / 20) * 3.0.squareRoot()
        var samples = (0..<count).map { _ in Float(noiseAmplitude * (2 * random() - 1)) }
        let speechAmplitude = pow(10, speechDBFS / 20)
        var position = Int(0.2 * rate)
        while position < count {
            let length = Int((0.12 + 0.18 * random()) * rate)
            let pitch = 100 + 80 * random()
            for i in 0..<length where position + i < count {
                let t = Double(i) / rate
                let envelope = sin(Double.pi * Double(i) / Double(length))
                var voiced = 0.0
                for harmonic in 1...6 { voiced += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic) }
                let breath = 2 * random() - 1
                samples[position + i] += Float(speechAmplitude * envelope * (0.6 * voiced + 0.3 * breath))
            }
            position += length + Int((1 / wordsPerSecond) * rate * (0.3 + 0.7 * random()))
        }
        return samples
    }

    static func scaled(_ samples: [Float], toLUFS target: Double) -> [Float] {
        let current = LoudnessMeter.integratedLoudness(channels: [samples], sampleRate: 48_000) ?? target
        let gain = Float(pow(10, (target - current) / 20))
        return samples.map { $0 * gain }
    }
}
