import Foundation

// Margin loudness (#465, slice 1 of #181). Whispered Margins played far quieter than the episode
// around them, and AVAudioPlayer's volume stops at 1.0, so a quiet recording needs a leveled copy.
// Everything here works on decoded samples, so it runs in the Linux suite too; decoding and
// writing files is SessionKitAudio's `MarginLoudnessLeveler`.

/// How loud a recording is, measured the way podcast audio is (ITU-R BS.1770-4, EBU R128).
public struct LoudnessMeasurement: Equatable, Sendable {
    /// Integrated loudness in LUFS: K-weighted and gated. Nil when nothing passes the -70 LUFS
    /// absolute gate (silence), because silence has no loudness to level.
    public var integratedLUFS: Double?
    /// The highest inter-sample peak, from 4x oversampling, in dBTP.
    public var truePeakDBTP: Double
    /// How loud the quiet stretches are: the 10th percentile of 50 ms RMS windows, in dBFS.
    public var noiseFloorDBFS: Double

    public init(integratedLUFS: Double?, truePeakDBTP: Double, noiseFloorDBFS: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.noiseFloorDBFS = noiseFloorDBFS
    }
}

public enum LoudnessMeter {
    /// Levels below this read as this, so silence gives finite numbers.
    public static let floorDB = -120.0
    static let blockSeconds = 0.4
    static let blockStepSeconds = 0.1
    static let absoluteGateLUFS = -70.0
    static let relativeGateLU = -10.0
    static let noiseWindowSeconds = 0.05
    static let noiseFloorPercentile = 0.10

    /// - Parameter channels: one array of samples per channel, all the same length, full scale ±1.
    ///   Mono and stereo weigh every channel 1.0; channels past the third are treated as
    ///   surrounds (1.41), as BS.1770 does for 5.1 in L, R, C, Ls, Rs order without the LFE.
    public static func measure(channels: [[Float]], sampleRate: Double) -> LoudnessMeasurement {
        LoudnessMeasurement(
            integratedLUFS: integratedLoudness(channels: channels, sampleRate: sampleRate),
            truePeakDBTP: truePeak(channels: channels),
            noiseFloorDBFS: noiseFloor(channels: channels, sampleRate: sampleRate)
        )
    }

    /// BS.1770-4 integrated loudness: K-weighting, 400 ms blocks overlapping by 75%, an absolute
    /// gate at -70 LUFS, then a relative gate 10 LU under the loudness of the blocks that passed.
    public static func integratedLoudness(channels: [[Float]], sampleRate: Double) -> Double? {
        guard let length = channels.first?.count, length > 0, sampleRate > 0 else { return nil }
        let weighted = channels.map { KWeighting(sampleRate: sampleRate).apply($0) }
        let blockLength = max(1, Int((blockSeconds * sampleRate).rounded()))
        let step = max(1, Int((blockStepSeconds * sampleRate).rounded()))
        // A recording shorter than one block is measured as one block of its own length.
        let starts = length < blockLength ? [0] : Array(stride(from: 0, through: length - blockLength, by: step))
        let span = min(blockLength, length)

        var blockPowers: [Double] = []
        blockPowers.reserveCapacity(starts.count)
        for start in starts {
            var power = 0.0
            for (index, channel) in weighted.enumerated() {
                var sum = 0.0
                channel.withUnsafeBufferPointer { samples in
                    for i in start..<(start + span) { sum += samples[i] * samples[i] }
                }
                power += channelWeight(index) * sum / Double(span)
            }
            blockPowers.append(power)
        }

        let aboveAbsolute = blockPowers.filter { loudness(ofPower: $0) > absoluteGateLUFS }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = loudness(ofPower: mean(aboveAbsolute)) + relativeGateLU
        let gated = aboveAbsolute.filter { loudness(ofPower: $0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(ofPower: mean(gated))
    }

    /// The highest absolute value of the signal oversampled 4x (BS.1770-4 Annex 2), in dBTP.
    public static func truePeak(channels: [[Float]]) -> Double {
        let peak = channels.map { TruePeakOversampler.peak(of: $0) }.max() ?? 0
        return decibels(amplitude: peak)
    }

    /// The 10th percentile of 50 ms RMS windows across the file (channels averaged by power), in dBFS.
    /// It is what a boost would lift the room noise and hiss to between words.
    public static func noiseFloor(channels: [[Float]], sampleRate: Double) -> Double {
        guard let length = channels.first?.count, length > 0 else { return floorDB }
        let window = max(1, Int((noiseWindowSeconds * sampleRate).rounded()))
        var levels: [Double] = []
        var start = 0
        repeat {
            let end = min(length, start + window)
            var power = 0.0
            for channel in channels {
                channel.withUnsafeBufferPointer { samples in
                    for i in start..<end { power += Double(samples[i]) * Double(samples[i]) }
                }
            }
            power /= Double((end - start) * channels.count)
            levels.append(max(floorDB, 10 * log10(max(power, 1e-30))))
            start += window
        } while start + window <= length
        levels.sort()
        let index = min(levels.count - 1, Int(Double(levels.count) * noiseFloorPercentile))
        return levels[index]
    }

    public static func decibels(amplitude: Double) -> Double {
        max(floorDB, 20 * log10(max(amplitude, 1e-30)))
    }

    static func loudness(ofPower power: Double) -> Double {
        -0.691 + 10 * log10(max(power, 1e-30))
    }

    private static func channelWeight(_ index: Int) -> Double { index < 3 ? 1.0 : 1.41 }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }
}

/// BS.1770-4's two-stage K-weighting filter (a high shelf, then a high-pass), with coefficients
/// derived for any sample rate by the bilinear transform libebur128 uses. At 48 kHz they equal the
/// standard's published coefficients (checked in LoudnessTests).
struct KWeighting {
    let stages: [Biquad]

    init(sampleRate: Double) {
        stages = [.kWeightingShelf(sampleRate: sampleRate), .kWeightingHighPass(sampleRate: sampleRate)]
    }

    func apply(_ samples: [Float]) -> [Double] {
        var output = samples.map(Double.init)
        for stage in stages { stage.process(&output) }
        return output
    }
}

struct Biquad: Equatable {
    var b0, b1, b2, a1, a2: Double

    static func kWeightingShelf(sampleRate: Double) -> Biquad {
        let frequency = 1_681.974450955533, gainDB = 3.999843853973347, q = 0.7071752369554196
        let k = tan(Double.pi * frequency / sampleRate)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    static func kWeightingHighPass(sampleRate: Double) -> Biquad {
        let frequency = 38.13547087602444, q = 0.5003270373238773
        let k = tan(Double.pi * frequency / sampleRate)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    /// Direct form I, in place.
    func process(_ samples: inout [Double]) {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        samples.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                let x0 = buffer[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                buffer[i] = y0
            }
        }
    }
}

/// 4x polyphase interpolation for true-peak detection: a 48-tap windowed-sinc low-pass
/// (12 taps per phase), the size BS.1770-4 Annex 2 describes.
enum TruePeakOversampler {
    static let factor = 4
    static let tapsPerPhase = 12

    /// phases[p][m] weights x[n - m] for the output sample p/4 of the way from x[n - 6] toward x[n - 5].
    static let phases: [[Double]] = {
        let length = factor * tapsPerPhase
        let centre = Double(length - 1) / 2
        // Kaiser window, beta 8: flat to well past a quarter of the sample rate at this length.
        let beta = 8.0
        func bessel(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1..<30 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        let taps = (0..<length).map { index -> Double in
            let t = (Double(index) - centre) / Double(factor)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let ratio = (Double(index) - centre) / centre
            return sinc * bessel(beta * (1 - ratio * ratio).squareRoot()) / bessel(beta)
        }
        return (0..<factor).map { phase in
            let raw = stride(from: phase, to: length, by: factor).map { taps[$0] }
            let sum = raw.reduce(0, +)
            return raw.map { $0 / sum }
        }
    }()

    /// The largest absolute value among the samples and the interpolated points between them.
    static func peak(of samples: [Float]) -> Double {
        let sampled = samples.reduce(0.0) { max($0, abs(Double($1))) }
        return max(sampled, interpolatedPeaks(samples).max() ?? 0)
    }

    /// For each step n, the largest absolute value of the 4 points interpolated between
    /// x[n - 6] and x[n - 5]. The result runs `tapsPerPhase` past the end of the input.
    static func interpolatedPeaks(_ samples: [Float]) -> [Double] {
        let count = samples.count
        let taps = tapsPerPhase
        let coefficients = phases.flatMap { $0 }
        var peaks = [Double](repeating: 0, count: count + taps)
        samples.withUnsafeBufferPointer { x in
            coefficients.withUnsafeBufferPointer { h in
                peaks.withUnsafeMutableBufferPointer { out in
                    for n in 0..<(count + taps) {
                        let low = max(0, n - count + 1)
                        let high = min(taps - 1, n)
                        guard low <= high else { continue }
                        var peak = 0.0
                        for phase in 0..<factor {
                            var value = 0.0
                            let base = phase * taps
                            for m in low...high { value += h[base + m] * Double(x[n - m]) }
                            peak = max(peak, abs(value))
                        }
                        out[n] = peak
                    }
                }
            }
        }
        return peaks
    }
}

/// How much to turn a Margin up or down for playback, and why.
public struct LoudnessLevelingPlan: Equatable, Sendable {
    public enum Limit: String, Equatable, Sendable {
        /// The full difference to the target.
        case target
        /// Capped at `LoudnessLeveling.maximumBoostDB`.
        case maximumBoost
        /// Capped so the noise floor doesn't rise above `LoudnessLeveling.maximumNoiseFloorAfterGainDBFS`.
        case noiseFloor
        /// Capped so the peak limiter never takes off more than `LoudnessLeveling.maximumLimiterReductionDB`.
        case truePeak
        /// Silence: nothing to level.
        case silent
    }

    public var gainDB: Double
    public var limit: Limit
    /// How far the limiter must pull the loudest peaks down to keep them at the ceiling.
    public var limiterReductionDB: Double
}

public enum LoudnessLeveling {
    /// Podcast playback loudness, the level Apple Podcasts and most shows aim for.
    public static let defaultTargetLUFS = -16.0
    public static let maximumBoostDB = 18.0
    /// Output peaks stay at or below this, inter-sample peaks included.
    public static let truePeakCeilingDBTP = -1.0
    /// A whisper's quiet stretches are room noise and hiss. Boosting past this makes the hiss a
    /// feature of the Margin, so a noisy recording gets less than the full boost.
    public static let maximumNoiseFloorAfterGainDBFS = -48.0
    /// The limiter may take up to this much off the loudest peaks. Speech peaks sit 15-20 dB above
    /// its loudness, so without this a whisper with one lip smack could barely be turned up.
    public static let maximumLimiterReductionDB = 6.0

    public static func plan(_ measured: LoudnessMeasurement, targetLUFS: Double = defaultTargetLUFS) -> LoudnessLevelingPlan {
        guard let integrated = measured.integratedLUFS else {
            return LoudnessLevelingPlan(gainDB: 0, limit: .silent, limiterReductionDB: 0)
        }
        var gain = targetLUFS - integrated
        var limit = LoudnessLevelingPlan.Limit.target
        if gain > maximumBoostDB {
            gain = maximumBoostDB
            limit = .maximumBoost
        }
        let noiseCap = maximumNoiseFloorAfterGainDBFS - measured.noiseFloorDBFS
        if gain > 0, gain > noiseCap {
            gain = max(0, noiseCap)
            limit = .noiseFloor
        }
        let peakCap = truePeakCeilingDBTP + maximumLimiterReductionDB - measured.truePeakDBTP
        if gain > peakCap {
            gain = peakCap
            limit = .truePeak
        }
        let reduction = max(0, measured.truePeakDBTP + gain - truePeakCeilingDBTP)
        return LoudnessLevelingPlan(gainDB: gain, limit: limit, limiterReductionDB: reduction)
    }

    /// Applies `gainDB`, then a look-ahead peak limiter so the output's true peak is at or below
    /// `truePeakCeilingDBTP`. The input arrays are not changed.
    public static func render(channels: [[Float]], gainDB: Double) -> [[Float]] {
        let gain = Float(pow(10, gainDB / 20))
        var output = channels.map { $0.map { $0 * gain } }
        PeakLimiter.limit(&output, ceiling: pow(10, (truePeakCeilingDBTP - PeakLimiter.marginDB) / 20))
        // The limiter works on the gain envelope, so a fast gain change can leave a few hundredths
        // of a dB over. A final trim settles it against the measured true peak.
        let peak = LoudnessMeter.truePeak(channels: output)
        if peak > truePeakCeilingDBTP {
            let trim = Float(pow(10, (truePeakCeilingDBTP - peak) / 20))
            output = output.map { $0.map { $0 * trim } }
        }
        return output
    }
}

/// A look-ahead limiter driven by the oversampled peak envelope. The gain needed at each sample is
/// min-filtered over ±`lookahead` and then averaged over the same span, so the smoothed gain is never
/// above what any sample needs; it then recovers with a `release` time constant.
enum PeakLimiter {
    static let lookaheadSeconds = 0.005
    static let releaseSeconds = 0.08
    static let marginDB = 0.3
    /// The limiter doesn't know the sample rate; Margins are recorded at 44.1 or 48 kHz.
    static let assumedSampleRate = 48_000.0

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
        let radius = max(1, Int(lookaheadSeconds * assumedSampleRate))
        let held = slidingMinimum(needed, radius: radius)
        let smoothed = movingAverage(held, radius: radius)
        let release = exp(-1 / (releaseSeconds * assumedSampleRate))
        var gain = 1.0
        var envelope = [Double](repeating: 1, count: length)
        for i in 0..<length {
            gain = min(smoothed[i], release * gain + (1 - release))
            envelope[i] = gain
        }
        for c in channels.indices {
            channels[c].withUnsafeMutableBufferPointer { samples in
                for i in samples.indices { samples[i] *= Float(envelope[i]) }
            }
        }
    }

    /// For each sample, the largest absolute value of the 4x-oversampled signal next to it.
    private static func oversampledEnvelope(_ samples: [Float]) -> [Double] {
        var envelope = samples.map { abs(Double($0)) }
        let delay = TruePeakOversampler.tapsPerPhase / 2
        for (n, peak) in TruePeakOversampler.interpolatedPeaks(samples).enumerated() {
            // Step n's points sit between x[n - 6] and x[n - 5]; charge both.
            for target in [n - delay, n - delay + 1] where target >= 0 && target < envelope.count {
                envelope[target] = max(envelope[target], peak)
            }
        }
        return envelope
    }

    private static func slidingMinimum(_ values: [Double], radius: Int) -> [Double] {
        // A monotonic deque: O(n) regardless of radius.
        var result = [Double](repeating: 1, count: values.count)
        var deque: [Int] = []
        var head = 0
        let count = values.count
        var next = 0
        for i in 0..<count {
            while next < count && next <= i + radius {
                while deque.count > head && values[deque[deque.count - 1]] >= values[next] { deque.removeLast() }
                deque.append(next)
                next += 1
            }
            while deque[head] < i - radius { head += 1 }
            result[i] = values[deque[head]]
        }
        return result
    }

    private static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for i in values.indices { prefix[i + 1] = prefix[i] + values[i] }
        return values.indices.map { i in
            // Every value within the radius is at most what sample i needs, so their mean is too.
            let low = max(0, i - radius), high = min(values.count - 1, i + radius)
            return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
        }
    }
}
