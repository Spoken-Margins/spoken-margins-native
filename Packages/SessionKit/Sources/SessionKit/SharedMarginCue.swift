import Foundation

/// The two-note chime played before a shared Margin's automatic prompt. Generated, so no audio
/// file ships for it. Moved out of Gate1AppModel unchanged (#469 hot-file ratchet).
public enum SharedMarginCue {
    public static func doubleChimeWAVData() -> Data {
        let sampleRate = 44_100
        let segments: [(frequency: Double, seconds: Double)] = [(880, 0.08), (0, 0.08), (1_175, 0.11)]
        var samples: [Int16] = []
        for segment in segments {
            let count = Int(Double(sampleRate) * segment.seconds)
            for index in 0..<count {
                guard segment.frequency > 0 else { samples.append(0); continue }
                let progress = Double(index) / Double(max(1, count - 1))
                let envelope = sin(.pi * progress)
                let value = sin(2 * .pi * segment.frequency * Double(index) / Double(sampleRate)) * envelope * 0.30
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        let payloadBytes = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        func appendASCII(_ value: String) { data.append(contentsOf: value.utf8) }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        appendASCII("RIFF"); appendLE(UInt32(36 + payloadBytes)); appendASCII("WAVEfmt ")
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)); appendLE(UInt16(2)); appendLE(UInt16(16)); appendASCII("data")
        appendLE(UInt32(payloadBytes)); samples.forEach { appendLE($0) }
        return data
    }
}
