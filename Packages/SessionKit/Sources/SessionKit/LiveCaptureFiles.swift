import Foundation

// Live capture (#2481): a ReplayKit broadcast extension receives the phone's app audio, and the app turns the
// capture into a Library item. This file is Foundation-only: the extension compiles it directly instead of
// linking SessionKit, the way the share extension compiles its shared files.

/// Where a live capture lives in the App Group container, and the files the app and the extension share.
///
/// - `LiveCapture/current-session.json`: written by the app before the broadcast starts, so the extension knows
///   which session to write.
/// - `LiveCapture/<id>/audio.pcm`: 16 kHz mono signed 16-bit little-endian samples, appended by the extension.
/// - `LiveCapture/<id>/status.json`: the extension's running report (format, levels, byte counts).
/// - `LiveCapture/<id>/margins.json`: Margins the listener added, written by the app as they are added, so a
///   crash between capture and import keeps them.
public enum LiveCaptureFiles {
    public static let appGroupIdentifier = "group.com.spokenmargins.native"
    public static let extensionBundleIdentifier = "com.spokenmargins.native.livecapture"
    public static let sampleRate: Double = 16_000
    public static let bytesPerSample = 2

    public static func root(in container: URL) -> URL {
        container.appending(path: "LiveCapture", directoryHint: .isDirectory)
    }

    public static func configURL(in container: URL) -> URL {
        root(in: container).appending(path: "current-session.json")
    }

    public static func sessionDirectory(id: String, in container: URL) -> URL {
        root(in: container).appending(path: id, directoryHint: .isDirectory)
    }

    public static func audioURL(id: String, in container: URL) -> URL {
        sessionDirectory(id: id, in: container).appending(path: "audio.pcm")
    }

    public static func statusURL(id: String, in container: URL) -> URL {
        sessionDirectory(id: id, in: container).appending(path: "status.json")
    }

    public static func marginsURL(id: String, in container: URL) -> URL {
        sessionDirectory(id: id, in: container).appending(path: "margins.json")
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }
}

/// What the app writes before the broadcast starts.
public struct LiveCaptureSessionConfig: Codable, Equatable, Sendable {
    public var sessionId: String
    public var createdAt: Date
    public var transcribe: Bool

    public init(sessionId: String, createdAt: Date, transcribe: Bool) {
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.transcribe = transcribe
    }
}

/// The format of the buffers the system hands the extension, read from each buffer at run time (it has been seen
/// at 22.05 and 44.1 kHz, Int16 big-endian and Float32).
public struct LiveCaptureSourceFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var bitsPerChannel: Int
    public var formatFlags: UInt32

    // CoreAudio's kAudioFormatFlag values, repeated so this file stays Foundation-only.
    public static let flagIsFloat: UInt32 = 1 << 0
    public static let flagIsBigEndian: UInt32 = 1 << 1
    public static let flagIsSignedInteger: UInt32 = 1 << 2
    public static let flagIsNonInterleaved: UInt32 = 1 << 5

    public init(sampleRate: Double, channels: Int, bitsPerChannel: Int, formatFlags: UInt32) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.formatFlags = formatFlags
    }

    public var isFloat: Bool { formatFlags & Self.flagIsFloat != 0 }
    public var isBigEndian: Bool { formatFlags & Self.flagIsBigEndian != 0 }
    public var isNonInterleaved: Bool { formatFlags & Self.flagIsNonInterleaved != 0 }

    /// A short line for the diagnostics row, such as "44100 Hz · 2 ch · Int16 BE".
    public var summary: String {
        let kind = isFloat ? "Float\(bitsPerChannel)" : "Int\(bitsPerChannel)"
        return "\(Int(sampleRate)) Hz · \(channels) ch · \(kind) \(isBigEndian ? "BE" : "LE")\(isNonInterleaved ? " planar" : "")"
    }
}

/// The extension's running report. The app polls it to show whether audio is arriving.
public struct LiveCaptureStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        case stopped
        case failed
    }

    public var sessionId: String
    public var state: State
    public var startedAt: Date
    public var updatedAt: Date
    /// When the first app-audio buffer arrived; the audio file's time zero.
    public var firstBufferAt: Date?
    public var lastBufferAt: Date?
    /// Samples written to `audio.pcm` at 16 kHz, silence padding included.
    public var samplesWritten: Int64
    /// Silence written to cover gaps where the system sent no buffers, so file time keeps pace with the clock.
    public var paddedSamples: Int64
    public var buffersReceived: Int
    /// Buffers whose every sample was zero. A call that arrives this way is being withheld by the system.
    public var zeroBuffers: Int
    /// Peak and RMS of roughly the last second, 0...1.
    public var peak: Float
    public var rms: Float
    public var sourceFormat: LiveCaptureSourceFormat?
    public var failure: String?

    public init(sessionId: String, state: State, startedAt: Date) {
        self.sessionId = sessionId
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.samplesWritten = 0
        self.paddedSamples = 0
        self.buffersReceived = 0
        self.zeroBuffers = 0
        self.peak = 0
        self.rms = 0
    }

    public var durationMs: Int {
        Int((Double(samplesWritten) / LiveCaptureFiles.sampleRate * 1_000).rounded())
    }
}

/// A Margin added during a capture, at its offset into the capture's audio.
public struct LiveCaptureMargin: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var offsetMs: Int
    public var createdAt: Date

    public init(id: String, text: String, offsetMs: Int, createdAt: Date) {
        self.id = id
        self.text = text
        self.offsetMs = offsetMs
        self.createdAt = createdAt
    }

    /// The offset of a Margin added at `now`: time since the first buffer, which is the audio file's time zero.
    /// Before any audio arrives the Margin sits at the start.
    public static func offsetMs(now: Date, firstBufferAt: Date?) -> Int {
        guard let firstBufferAt else { return 0 }
        return max(0, Int((now.timeIntervalSince(firstBufferAt) * 1_000).rounded()))
    }
}
