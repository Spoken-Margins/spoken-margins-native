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
    ///   The caller must pass channels in that order with the LFE removed; this can't tell a
    ///   layout from a channel count. `MarginLoudnessLeveler` only accepts mono and stereo files.
    public static func measure(channels: [[Float]], sampleRate: Double) -> LoudnessMeasurement {
        var meter = Accumulator(channelCount: channels.count, sampleRate: sampleRate)
        meter.add(channels)
        return meter.finish()
    }

    /// BS.1770-4 integrated loudness: K-weighting, 400 ms blocks overlapping by 75%, an absolute
    /// gate at -70 LUFS, then a relative gate 10 LU under the loudness of the blocks that passed.
    public static func integratedLoudness(channels: [[Float]], sampleRate: Double) -> Double? {
        var gated = GatedLoudness(channelCount: channels.count, sampleRate: sampleRate)
        gated.add(channels)
        return gated.finish()
    }

    /// The highest absolute value of the signal oversampled 4x (BS.1770-4 Annex 2), in dBTP.
    public static func truePeak(channels: [[Float]]) -> Double {
        var peak = TruePeak(channelCount: channels.count)
        peak.add(channels)
        return peak.finish()
    }

    /// The 10th percentile of 50 ms RMS windows across the file (channels averaged by power), in dBFS.
    /// It is what a boost would lift the room noise and hiss to between words.
    public static func noiseFloor(channels: [[Float]], sampleRate: Double) -> Double {
        var floor = NoiseFloor(channelCount: channels.count, sampleRate: sampleRate)
        floor.add(channels)
        return floor.finish()
    }

    public static func decibels(amplitude: Double) -> Double {
        max(floorDB, 20 * log10(max(amplitude, 1e-30)))
    }

    static func loudness(ofPower power: Double) -> Double {
        -0.691 + 10 * log10(max(power, 1e-30))
    }

    fileprivate static func channelWeight(_ index: Int) -> Double { index < 3 ? 1.0 : 1.41 }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    /// Measures a recording fed in chunks of any size (#731), so a long Margin never has to be in
    /// memory at once. Feeding the same samples in any chunking gives the same measurement as
    /// `measure(channels:sampleRate:)`, which is built on this. It keeps about 30 numbers per second
    /// of audio (a loudness per 100 ms block, a level per 50 ms window), not the samples.
    public struct Accumulator {
        private var gated: GatedLoudness
        private var peak: TruePeak
        private var floor: NoiseFloor

        public init(channelCount: Int, sampleRate: Double) {
            gated = GatedLoudness(channelCount: channelCount, sampleRate: sampleRate)
            peak = TruePeak(channelCount: channelCount)
            floor = NoiseFloor(channelCount: channelCount, sampleRate: sampleRate)
        }

        /// - Parameter chunk: the next samples, one array per channel, all the same length.
        public mutating func add(_ chunk: [[Float]]) {
            gated.add(chunk)
            peak.add(chunk)
            floor.add(chunk)
        }

        /// The measurement of everything added so far. More can still be added afterwards.
        public func finish() -> LoudnessMeasurement {
            LoudnessMeasurement(integratedLUFS: gated.finish(), truePeakDBTP: peak.finish(), noiseFloorDBFS: floor.finish())
        }
    }

    /// Integrated loudness, fed in chunks. Blocks start every 100 ms and are summed as their samples
    /// arrive; a block is kept once all 400 ms of it have been seen.
    struct GatedLoudness {
        private let sampleRate: Double
        private let blockLength: Int
        private let step: Int
        private var filters: [KWeighting]
        private var frames = 0
        private var nextBlockStart = 0
        /// Blocks still waiting for samples: where each starts and its per-channel sum of squares.
        private var openBlocks: [(start: Int, sums: [Double])] = []
        private var blockPowers: [Double] = []

        init(channelCount: Int, sampleRate: Double) {
            self.sampleRate = sampleRate
            let rate = sampleRate > 0 ? sampleRate : 0
            blockLength = max(1, Int((blockSeconds * rate).rounded()))
            step = max(1, Int((blockStepSeconds * rate).rounded()))
            filters = sampleRate > 0 ? (0..<channelCount).map { _ in KWeighting(sampleRate: sampleRate) } : []
        }

        mutating func add(_ chunk: [[Float]]) {
            guard !filters.isEmpty, let count = chunk.first?.count, count > 0 else { return }
            precondition(chunk.count == filters.count, "a chunk must have one array per channel")
            let weighted = chunk.indices.map { filters[$0].apply(chunk[$0]) }
            while nextBlockStart < frames + count {
                openBlocks.append((nextBlockStart, [Double](repeating: 0, count: chunk.count)))
                nextBlockStart += step
            }
            for block in openBlocks.indices {
                let start = openBlocks[block].start
                let from = max(start, frames), to = min(start + blockLength, frames + count)
                guard from < to else { continue }
                for (channel, samples) in weighted.enumerated() {
                    var sum = openBlocks[block].sums[channel]
                    samples.withUnsafeBufferPointer { buffer in
                        guard let samples = buffer.baseAddress else { return }
                        var i = from - frames
                        while i < to - frames {
                            sum += samples[i] * samples[i]
                            i += 1
                        }
                    }
                    openBlocks[block].sums[channel] = sum
                }
            }
            frames += count
            while let first = openBlocks.first, first.start + blockLength <= frames {
                blockPowers.append(Self.power(first.sums, span: blockLength))
                openBlocks.removeFirst()
            }
        }

        func finish() -> Double? {
            guard frames > 0 else { return nil }
            var powers = blockPowers
            // A recording shorter than one block is measured as one block of its own length.
            if frames < blockLength, let first = openBlocks.first {
                powers = [Self.power(first.sums, span: frames)]
            }
            let aboveAbsolute = powers.filter { loudness(ofPower: $0) > absoluteGateLUFS }
            guard !aboveAbsolute.isEmpty else { return nil }
            let relativeGate = loudness(ofPower: mean(aboveAbsolute)) + relativeGateLU
            let gated = aboveAbsolute.filter { loudness(ofPower: $0) > relativeGate }
            guard !gated.isEmpty else { return nil }
            return loudness(ofPower: mean(gated))
        }

        private static func power(_ sums: [Double], span: Int) -> Double {
            var power = 0.0
            for (index, sum) in sums.enumerated() { power += channelWeight(index) * sum / Double(span) }
            return power
        }
    }

    /// True peak, fed in chunks: each channel's oversampler carries its last few samples over.
    struct TruePeak {
        private var oversamplers: [TruePeakOversampler.Stream]
        private var peak = 0.0

        init(channelCount: Int) {
            oversamplers = Array(repeating: TruePeakOversampler.Stream(), count: channelCount)
        }

        mutating func add(_ chunk: [[Float]]) {
            precondition(chunk.isEmpty || chunk.count == oversamplers.count, "a chunk must have one array per channel")
            for (channel, samples) in chunk.enumerated() {
                let sampled = samples.reduce(0.0) { max($0, abs(Double($1))) }
                peak = max(peak, sampled, oversamplers[channel].interpolatedPeaks(samples).max() ?? 0)
            }
        }

        func finish() -> Double {
            var flushed = oversamplers
            let tail = flushed.indices.map { flushed[$0].flush().max() ?? 0 }.max() ?? 0
            return decibels(amplitude: max(peak, tail))
        }
    }

    /// Noise floor, fed in chunks: a level per full 50 ms window. A recording shorter than one
    /// window is measured as one window of its own length; a partial window at the end is left out.
    struct NoiseFloor {
        private let window: Int
        private var current: [[Float]]
        private var frames = 0
        private var levels: [Double] = []

        init(channelCount: Int, sampleRate: Double) {
            window = sampleRate > 0 ? max(1, Int((noiseWindowSeconds * sampleRate).rounded())) : 1
            current = Array(repeating: [], count: channelCount)
        }

        mutating func add(_ chunk: [[Float]]) {
            guard !current.isEmpty, let count = chunk.first?.count, count > 0 else { return }
            precondition(chunk.count == current.count, "a chunk must have one array per channel")
            var offset = 0
            while offset < count {
                let take = min(window - current[0].count, count - offset)
                for channel in current.indices { current[channel].append(contentsOf: chunk[channel][offset..<(offset + take)]) }
                offset += take
                if current[0].count == window {
                    levels.append(Self.level(current))
                    for channel in current.indices { current[channel].removeAll(keepingCapacity: true) }
                }
            }
            frames += count
        }

        func finish() -> Double {
            guard frames > 0 else { return floorDB }
            var sorted = levels.isEmpty ? [Self.level(current)] : levels
            sorted.sort()
            let index = min(sorted.count - 1, Int(Double(sorted.count) * noiseFloorPercentile))
            return sorted[index]
        }

        private static func level(_ channels: [[Float]]) -> Double {
            var power = 0.0
            for channel in channels {
                for sample in channel { power += Double(sample) * Double(sample) }
            }
            power /= Double(channels[0].count * channels.count)
            return max(floorDB, 10 * log10(max(power, 1e-30)))
        }
    }
}

/// BS.1770-4's two-stage K-weighting filter (a high shelf, then a high-pass), with coefficients
/// derived for any sample rate by the bilinear transform libebur128 uses. At 48 kHz they equal the
/// standard's published coefficients (checked in LoudnessTests).
/// It keeps each stage's memory, so a recording can be filtered a chunk at a time.
struct KWeighting {
    let stages: [Biquad]
    private var memory: [Biquad.Memory]

    init(sampleRate: Double) {
        stages = [.kWeightingShelf(sampleRate: sampleRate), .kWeightingHighPass(sampleRate: sampleRate)]
        memory = Array(repeating: Biquad.Memory(), count: stages.count)
    }

    /// Filters the next samples, carrying on from where the last call stopped.
    mutating func apply(_ samples: [Float]) -> [Double] {
        var output = [Double](unsafeUninitializedCapacity: samples.count) { buffer, initialized in
            samples.withUnsafeBufferPointer { input in
                var i = 0
                while i < input.count {
                    buffer[i] = Double(input[i])
                    i += 1
                }
            }
            initialized = samples.count
        }
        for index in stages.indices { stages[index].process(&output, memory: &memory[index]) }
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

    /// The last two inputs and outputs, carried from one chunk to the next.
    struct Memory: Equatable {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    }

    /// Direct form I, in place.
    func process(_ samples: inout [Double], memory: inout Memory) {
        var x1 = memory.x1, x2 = memory.x2, y1 = memory.y1, y2 = memory.y2
        let b0 = b0, b1 = b1, b2 = b2, a1 = a1, a2 = a2
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let samples = buffer.baseAddress else { return }
            var i = 0
            while i < buffer.count {
                let x0 = samples[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                samples[i] = y0
                i += 1
            }
        }
        memory = Memory(x1: x1, x2: x2, y1: y1, y2: y2)
    }
}

/// 4x polyphase interpolation for true-peak detection: a 48-tap windowed-sinc low-pass
/// (12 taps per phase), the size BS.1770-4 Annex 2 describes.
enum TruePeakOversampler {
    static let factor = 4
    /// `Stream.interpolatedPeaks` writes these taps out one by one.
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

    static let coefficients = phases.flatMap { $0 }

    /// Interpolates a signal fed in chunks. It keeps the last `tapsPerPhase - 1` samples, so each
    /// call returns one peak per new sample, whatever the chunking.
    struct Stream {
        private var history = [Float](repeating: 0, count: tapsPerPhase - 1)

        /// For each new sample x[n], the largest absolute value of the 4 points interpolated between
        /// x[n - 6] and x[n - 5]. Samples before the first count as zero.
        mutating func interpolatedPeaks(_ samples: [Float]) -> [Double] {
            let taps = tapsPerPhase
            let count = samples.count
            let work = history + samples
            var peaks = [Double](repeating: 0, count: count)
            // Plain while loops and pointer arithmetic: the package's tests run unoptimized, where
            // ranges, generic max/abs and buffer subscripts cost a call each, and this loop runs
            // 48 times per sample (#465's tests went past the lane's host-test time limit).
            work.withUnsafeBufferPointer { xBuffer in
                coefficients.withUnsafeBufferPointer { hBuffer in
                    peaks.withUnsafeMutableBufferPointer { outBuffer in
                        guard let x = xBuffer.baseAddress, let h = hBuffer.baseAddress, let out = outBuffer.baseAddress else { return }
                        var k = 0
                        while k < count {
                            let n = k + taps - 1
                            var peak = 0.0
                            var phase = 0
                            while phase < factor {
                                // The 12 taps written out, summed in order (the loop cost more than the sums).
                                let row = h + phase * taps
                                let xn = x + n
                                var value = 0.0
                                value += row[0] * Double(xn[0])
                                value += row[1] * Double(xn[-1])
                                value += row[2] * Double(xn[-2])
                                value += row[3] * Double(xn[-3])
                                value += row[4] * Double(xn[-4])
                                value += row[5] * Double(xn[-5])
                                value += row[6] * Double(xn[-6])
                                value += row[7] * Double(xn[-7])
                                value += row[8] * Double(xn[-8])
                                value += row[9] * Double(xn[-9])
                                value += row[10] * Double(xn[-10])
                                value += row[11] * Double(xn[-11])
                                let magnitude = value < 0 ? -value : value
                                if magnitude > peak { peak = magnitude }
                                phase += 1
                            }
                            out[k] = peak
                            k += 1
                        }
                    }
                }
            }
            history = Array(work.suffix(taps - 1))
            return peaks
        }

        /// The `tapsPerPhase` interpolated peaks that run past the last sample, as if zeros followed.
        mutating func flush() -> [Double] {
            interpolatedPeaks([Float](repeating: 0, count: tapsPerPhase))
        }
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
        var renderer = Renderer(channelCount: channels.count, gainDB: gainDB)
        var output = renderer.process(channels)
        for (channel, tail) in renderer.finish().enumerated() { output[channel] += tail }
        if let trim = ceilingTrim(forTruePeakDBTP: LoudnessMeter.truePeak(channels: output)) {
            output = output.map { $0.map { $0 * trim } }
        }
        return output
    }

    /// The limiter works on the gain envelope, so a fast gain change can leave a few hundredths of a
    /// dB over the ceiling. Given the rendered copy's true peak, this is the factor that settles it,
    /// or nil when the copy is already at or under the ceiling.
    public static func ceilingTrim(forTruePeakDBTP peak: Double) -> Float? {
        guard peak > truePeakCeilingDBTP else { return nil }
        return Float(pow(10, (truePeakCeilingDBTP - peak) / 20))
    }

    /// Applies a gain and the peak limiter to a recording fed in chunks (#731). Each call returns
    /// the frames the limiter has settled, `lookAheadFrames` behind what has been fed; `finish`
    /// returns the rest. Concatenated, the output is the same whatever the chunking. The final
    /// trim needs the whole output's true peak, so callers apply `ceilingTrim` afterwards.
    public struct Renderer {
        /// How far the output trails the input: the limiter has to see this far ahead before it
        /// can settle a sample's gain. About 10 ms.
        public static var lookAheadFrames: Int { PeakLimiter.latency }

        public let channelCount: Int
        private let gain: Float
        private var limiter: PeakLimiter

        public init(channelCount: Int, gainDB: Double) {
            self.channelCount = channelCount
            gain = Float(pow(10, gainDB / 20))
            limiter = PeakLimiter(
                channelCount: channelCount,
                ceiling: pow(10, (truePeakCeilingDBTP - PeakLimiter.marginDB) / 20)
            )
        }

        /// Frames fed in but not yet returned; never more than `lookAheadFrames`.
        public var bufferedFrames: Int { limiter.bufferedFrames }

        /// - Parameter chunk: the next samples, one array per channel, all the same length.
        public mutating func process(_ chunk: [[Float]]) -> [[Float]] {
            limiter.process(chunk.map { $0.map { $0 * gain } })
        }

        /// The frames still held back. Nothing more may be fed after this.
        public mutating func finish() -> [[Float]] {
            limiter.finish()
        }
    }
}

/// A look-ahead limiter driven by the oversampled peak envelope. The gain needed at each sample is
/// min-filtered over ±`lookahead` and then averaged over the same span, so the smoothed gain is never
/// above what any sample needs; it then recovers with a `release` time constant.
///
/// It runs on a stream (#731): each stage (envelope, sliding minimum, moving average, release)
/// finishes a sample as soon as it has seen far enough ahead, and keeps only that far back.
struct PeakLimiter {
    static let lookaheadSeconds = 0.005
    static let releaseSeconds = 0.08
    static let marginDB = 0.3
    /// The limiter doesn't know the sample rate; Margins are recorded at 44.1 or 48 kHz.
    static let assumedSampleRate = 48_000.0
    static let radius = max(1, Int(lookaheadSeconds * assumedSampleRate))
    /// Step n's interpolated points sit between x[n - 6] and x[n - 5], so a sample's envelope is
    /// complete 6 samples later.
    static let envelopeLookahead = TruePeakOversampler.tapsPerPhase / 2
    /// A sample's envelope needs 6 samples on, its minimum `radius` more, and the average of those
    /// minimums `radius` more again.
    static let latency = 2 * radius + envelopeLookahead

    private let ceiling: Double
    private let release: Double
    private var oversamplers: [TruePeakOversampler.Stream]
    private var finished = false

    // Each count is how many samples have passed that stage, from the start of the recording.
    private var fed = 0
    private var enveloped = 0
    private var held = 0
    private var smoothedCount = 0
    private var returned = 0

    /// Each channel's samples from `returned` up to `fed`.
    private var pending: [[Float]]
    /// Each channel's interpolated peaks from step `enveloped + 5` on. Steps 0 to 4 touch no
    /// sample's envelope, so they are dropped as they come.
    private var peaks: [[Double]]
    private var stepsToSkip = envelopeLookahead - 1
    /// The gain each sample needs, from sample `neededBase` up to `enveloped`.
    private var needed: [Double] = []
    private var neededBase = 0
    /// The sliding minimum's candidates (samples whose needed gains increase), a ring from
    /// `candidateHead` to `candidateTail`, and the next sample to offer it. They span at most
    /// 2 × radius + 2 samples.
    private var candidates: [Int]
    private var candidateHead = 0
    private var candidateTail = 0
    private var nextCandidate = 0
    /// Running sums of the held gains: slot k % count holds the sum of held gains 0 to k - 1, for the
    /// last 2 × radius + 2 values of k, which is as far back as the moving average reaches. Every
    /// held gain in an average is at most what the sample in the middle needs, so the mean is too.
    private var prefix: [Double]
    /// Smoothed gains for samples `returned` up to `smoothedCount`, waiting to be applied.
    private var smoothed: [Double] = []
    private var gain = 1.0

    init(channelCount: Int, ceiling: Double) {
        self.ceiling = ceiling
        release = exp(-1 / (Self.releaseSeconds * Self.assumedSampleRate))
        oversamplers = Array(repeating: TruePeakOversampler.Stream(), count: channelCount)
        pending = Array(repeating: [], count: channelCount)
        peaks = Array(repeating: [], count: channelCount)
        prefix = [Double](repeating: 0, count: 2 * Self.radius + 2)
        candidates = [Int](repeating: 0, count: 2 * Self.radius + 4)
    }

    var bufferedFrames: Int { fed - returned }

    mutating func process(_ chunk: [[Float]]) -> [[Float]] {
        precondition(!finished, "nothing may be fed after finish")
        precondition(chunk.count == pending.count, "a chunk must have one array per channel")
        guard let count = chunk.first?.count, count > 0 else { return Array(repeating: [], count: pending.count) }
        for (channel, samples) in chunk.enumerated() {
            pending[channel].append(contentsOf: samples)
            addPeaks(oversamplers[channel].interpolatedPeaks(samples), channel: channel)
        }
        fed += count
        // A sample's envelope needs two interpolated steps: i + 5 and i + 6.
        let ready = min(fed - enveloped, (peaks.map(\.count).min() ?? 0) - 1)
        envelope(ready)
        hold(through: enveloped - Self.radius, atEnd: false)
        return emit()
    }

    mutating func finish() -> [[Float]] {
        precondition(!finished, "finish may only be called once")
        finished = true
        guard fed > 0 else { return Array(repeating: [], count: pending.count) }
        for channel in peaks.indices { addPeaks(oversamplers[channel].flush(), channel: channel) }
        envelope(fed - enveloped)
        // Past the last sample the windows stop at the end, as the whole-recording limiter's did.
        hold(through: fed, atEnd: true)
        return emit()
    }

    private mutating func addPeaks(_ new: [Double], channel: Int) {
        let skip = min(stepsToSkip, new.count)
        peaks[channel].append(contentsOf: new[skip...])
        if channel == peaks.count - 1 { stepsToSkip -= skip }
    }

    /// Works out the gain the next `count` samples need to stay under the ceiling, from each one's
    /// largest neighbouring oversampled peak in any channel.
    private mutating func envelope(_ count: Int) {
        guard count > 0 else { return }
        var gains = [Double](repeating: 1, count: count)
        let offset = enveloped - returned
        let ceiling = ceiling
        for channel in pending.indices {
            pending[channel].withUnsafeBufferPointer { x in
                peaks[channel].withUnsafeBufferPointer { p in
                    gains.withUnsafeMutableBufferPointer { g in
                        var j = 0
                        while j < count {
                            var envelope = Double(x[offset + j])
                            if envelope < 0 { envelope = -envelope }
                            if p[j] > envelope { envelope = p[j] }
                            if p[j + 1] > envelope { envelope = p[j + 1] }
                            if envelope > ceiling, ceiling / envelope < g[j] { g[j] = ceiling / envelope }
                            j += 1
                        }
                    }
                }
            }
            peaks[channel].removeFirst(count)
        }
        needed.append(contentsOf: gains)
        enveloped += count
    }

    /// Finishes the held gain (the smallest needed gain within `radius`) of each sample before
    /// `end`, and the smoothed gain of each sample whose window of held gains is then complete.
    private mutating func hold(through end: Int, atEnd: Bool) {
        let radius = Self.radius
        let base = neededBase, enveloped = enveloped
        var held = held, smoothedCount = smoothedCount, nextCandidate = nextCandidate
        var head = candidateHead, tail = candidateTail
        var newSmoothed: [Double] = []
        newSmoothed.reserveCapacity(max(0, end - held))
        // Pointers, not array subscripts: the package's tests run unoptimized, and this runs per sample.
        needed.withUnsafeBufferPointer { need in
            candidates.withUnsafeMutableBufferPointer { ring in
                prefix.withUnsafeMutableBufferPointer { sums in
                    let slots = ring.count, sumSlots = sums.count
                    func average(_ low: Int, _ high: Int) -> Double {
                        (sums[(high + 1) % sumSlots] - sums[low % sumSlots]) / Double(high - low + 1)
                    }
                    while held < end {
                        let reach = held + radius < enveloped - 1 ? held + radius : enveloped - 1
                        while nextCandidate <= reach {
                            let value = need[nextCandidate - base]
                            while tail > head, need[ring[(tail - 1) % slots] - base] >= value { tail -= 1 }
                            ring[tail % slots] = nextCandidate
                            tail += 1
                            nextCandidate += 1
                        }
                        while ring[head % slots] < held - radius { head += 1 }
                        sums[(held + 1) % sumSlots] = sums[held % sumSlots] + need[ring[head % slots] - base]
                        held += 1
                        if smoothedCount + radius < held {
                            newSmoothed.append(average(smoothedCount - radius > 0 ? smoothedCount - radius : 0, smoothedCount + radius))
                            smoothedCount += 1
                        }
                    }
                    if atEnd {
                        while smoothedCount < held {
                            newSmoothed.append(average(smoothedCount - radius > 0 ? smoothedCount - radius : 0, held - 1))
                            smoothedCount += 1
                        }
                    }
                }
            }
        }
        self.held = held
        self.smoothedCount = smoothedCount
        self.nextCandidate = nextCandidate
        candidateHead = head
        candidateTail = tail
        smoothed.append(contentsOf: newSmoothed)
        // The candidates all sit within `radius` of the last held sample; drop needed gains before that.
        let keepFrom = max(base, held - 1 - radius)
        needed.removeFirst(keepFrom - base)
        neededBase = keepFrom
    }

    /// Applies the smoothed gains with the release and hands those samples out.
    private mutating func emit() -> [[Float]] {
        let count = smoothed.count
        var gain = gain
        let release = release
        let gains = [Float](unsafeUninitializedCapacity: count) { out, initialized in
            smoothed.withUnsafeBufferPointer { smoothed in
                var j = 0
                while j < count {
                    gain = min(smoothed[j], release * gain + (1 - release))
                    out[j] = Float(gain)
                    j += 1
                }
            }
            initialized = count
        }
        self.gain = gain
        let output = pending.map { channel in
            [Float](unsafeUninitializedCapacity: count) { out, initialized in
                channel.withUnsafeBufferPointer { x in
                    gains.withUnsafeBufferPointer { g in
                        var j = 0
                        while j < count {
                            out[j] = x[j] * g[j]
                            j += 1
                        }
                    }
                }
                initialized = count
            }
        }
        for channel in pending.indices { pending[channel].removeFirst(count) }
        smoothed.removeAll(keepingCapacity: true)
        returned += count
        return output
    }
}
