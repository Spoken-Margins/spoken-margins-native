import Foundation

// Foundation-only (the live capture extension compiles it directly, #2481).

/// Turns the broadcast's app-audio buffers into the capture file's 16 kHz mono 16-bit samples.
public enum LiveCapturePCM {
    /// Decodes one buffer to mono Float samples by averaging channels. `buffers` holds one Data per
    /// AudioBuffer: one interleaved buffer, or one per channel when the format is non-interleaved.
    /// Formats other than Int16, Int32 and Float32/64 return no samples.
    public static func monoSamples(buffers: [Data], format: LiveCaptureSourceFormat) -> [Float] {
        let bytes = format.bitsPerChannel / 8
        guard bytes > 0, format.channels > 0, !buffers.isEmpty else { return [] }
        if format.isNonInterleaved {
            let planes = buffers.map { decode($0, format: format, bytes: bytes) }
            let frames = planes.map(\.count).min() ?? 0
            guard frames > 0 else { return [] }
            var mono = [Float](repeating: 0, count: frames)
            for plane in planes {
                for index in 0..<frames { mono[index] += plane[index] }
            }
            let scale = 1 / Float(planes.count)
            return mono.map { $0 * scale }
        }
        let samples = decode(buffers[0], format: format, bytes: bytes)
        let channels = format.channels
        let frames = samples.count / channels
        guard channels > 1 else { return samples }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            mono[frame] = sum * scale
        }
        return mono
    }

    private static func decode(_ data: Data, format: LiveCaptureSourceFormat, bytes: Int) -> [Float] {
        let count = data.count / bytes
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [Float] in
            var out = [Float](repeating: 0, count: count)
            switch (format.isFloat, bytes) {
            case (false, 2):
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                    let value = Int16(bitPattern: format.isBigEndian ? UInt16(bigEndian: bits) : UInt16(littleEndian: bits))
                    out[index] = Float(value) / 32_768
                }
            case (false, 4):
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    let value = Int32(bitPattern: format.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
                    out[index] = Float(Double(value) / 2_147_483_648)
                }
            case (true, 4):
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                    out[index] = Float(bitPattern: format.isBigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
                }
            case (true, 8):
                for index in 0..<count {
                    let bits = raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)
                    out[index] = Float(Double(bitPattern: format.isBigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)))
                }
            default:
                return []
            }
            return out
        }
    }

    /// 16-bit little-endian bytes, clipped.
    public static func int16LittleEndian(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (index, sample) in samples.enumerated() {
                let clipped = max(-1, min(1, sample.isFinite ? sample : 0))
                let value = Int16((clipped * 32_767).rounded())
                raw.storeBytes(of: UInt16(bitPattern: value).littleEndian, toByteOffset: index * 2, as: UInt16.self)
            }
        }
        return data
    }

    public static func peakAndRMS(_ samples: [Float]) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var squares: Double = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            squares += Double(sample) * Double(sample)
        }
        return (peak, Float((squares / Double(samples.count)).squareRoot()))
    }

    /// Silence to write before a buffer so the file keeps pace with the clock: the system sends no buffers while
    /// nothing plays, and Margins are placed by wall-clock time. `elapsedSeconds` is the buffer's presentation
    /// time minus the first buffer's. Gaps shorter than `tolerance` are left alone (buffer jitter).
    public static func silencePaddingSamples(
        writtenSamples: Int64, elapsedSeconds: Double, sampleRate: Double = LiveCaptureFiles.sampleRate, tolerance: Double = 0.25
    ) -> Int64 {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else { return 0 }
        let expected = Int64((elapsedSeconds * sampleRate).rounded())
        let gap = expected - writtenSamples
        return Double(gap) > tolerance * sampleRate ? gap : 0
    }
}

/// A streaming linear resampler to 16 kHz that carries its phase between buffers, so a capture split into
/// buffers resamples the same as one long buffer. Linear is enough for speech going to a listener and a
/// speech recognizer; it is not a mastering resampler.
public struct LiveCaptureResampler: Sendable {
    public let targetRate: Double
    private var sourceRate: Double?
    private var last: Float?
    /// Where the next output sample sits, in source samples, relative to the start of the next input buffer
    /// (-1 is the previous buffer's last sample).
    private var position: Double = 0

    public init(targetRate: Double = LiveCaptureFiles.sampleRate) {
        self.targetRate = targetRate
    }

    public mutating func process(_ input: [Float], sourceRate: Double) -> [Float] {
        guard !input.isEmpty, sourceRate > 0 else { return [] }
        if self.sourceRate != sourceRate {
            self.sourceRate = sourceRate
            last = nil
            position = 0
        }
        if sourceRate == targetRate {
            last = input.last
            return input
        }
        let step = sourceRate / targetRate
        let lastIndex = Double(input.count - 1)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 2)
        var t = max(position, last == nil ? 0 : -1)
        while t < lastIndex {
            let base = Int(t.rounded(.down))
            let fraction = Float(t - Double(base))
            let a = base < 0 ? (last ?? input[0]) : input[base]
            let b = input[base + 1]
            output.append(a + (b - a) * fraction)
            t += step
        }
        position = t - Double(input.count)
        last = input[input.count - 1]
        return output
    }
}
