import Foundation
import SessionKit

#if canImport(AVFoundation)

/// Turns a written Margin's words into an audio file the Margin-moment conductor plays as it plays a recording (#3365):
/// the same tone, the same pause of the episode, the same skip, interruption and heard-marking, with no second playback
/// machine. The iPhone's voice does the reading (`SystemTextAudioPreparationClient`, `AVSpeechSynthesizer.write`) for
/// everyone. It takes (words, spoken intro, voice), not a Margin, so the listener's chosen voice and the reading of an
/// episode's quote can use it later.
///
/// A file's path comes from its words and voice alone, so a caller can name the file without touching the disk and the
/// render can happen any time before the Margin plays. A render is written to a scratch folder and moved into place only
/// when complete, so a file that exists is whole. Everything that touches the disk runs off the main thread, and
/// `isReady` answers from memory, so the main thread can ask whether a reading is there without a file check.
///
/// `AVSpeechSynthesizer.write` can block its caller for minutes while the speech service loads (#1230), so every render
/// has a time limit. A render that outlasts it is abandoned: its waiters get `RenderError.timedOut`, its thread is left
/// to finish or not (the synthesizer is never released mid-write), and the next reading starts on a fresh lane.
public final class WrittenMarginReader: @unchecked Sendable {
    public static let shared = WrittenMarginReader()

    /// Where rendered readings are kept. Caches, so the system may clear them and the next play renders again. Built
    /// from the path alone: nothing is read or created.
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "SpokenMargins/WrittenMargins", directoryHint: .isDirectory)
    }

    /// The time a render may take before it is given up on: 20 seconds, which is the length of a review's lead-in, plus
    /// one second for every 500 characters, so a long note is not cut off for being long. The listener is waiting with
    /// the episode paused, so this is shorter than the 30 s the chunk renderer allows (`SystemVoiceChunkRenderer`).
    public static func defaultTimeLimit(forCharacters count: Int) -> TimeInterval { 20 + TimeInterval(count / 500) }

    public enum RenderError: Error, Equatable { case nothingToSay, timedOut }

    private final class Job: @unchecked Sendable {
        let reading: WrittenMarginReading
        let target: URL
        var finished = false
        init(reading: WrittenMarginReading, target: URL) { self.reading = reading; self.target = target }
    }

    private let directory: URL
    private let voiceIdentifier: String?
    private let renderAudio: @Sendable (_ spokenText: String, _ scratch: URL) throws -> URL
    private let timeLimit: @Sendable (_ spokenText: String) -> TimeInterval
    private let lock = NSLock()
    private var ready = Set<String>()
    private var waiting: [String: [@Sendable (Result<URL, Error>) -> Void]] = [:]
    private var pending: [Job] = []
    private var laneBusy = false
    private var lane = 0

    /// `renderAudio` writes the speech for `spokenText` somewhere under `scratch` and returns that file. The default is
    /// the iPhone voice.
    public init(
        directory: URL = WrittenMarginReader.defaultDirectory,
        voiceIdentifier: String? = nil,
        timeLimit: (@Sendable (_ spokenText: String) -> TimeInterval)? = nil,
        renderAudio: (@Sendable (_ spokenText: String, _ scratch: URL) throws -> URL)? = nil
    ) {
        self.directory = directory
        self.voiceIdentifier = voiceIdentifier
        self.timeLimit = timeLimit ?? { WrittenMarginReader.defaultTimeLimit(forCharacters: $0.count) }
        self.renderAudio = renderAudio ?? { text, scratch in
            let client = SystemTextAudioPreparationClient(outputDirectory: scratch, voiceIdentifier: voiceIdentifier)
            guard let prepared = try client.prepareTextAudio(itemId: "written-margin", title: "Written Margin", text: text),
                  let url = prepared.media.url.flatMap({ URL(string: $0) }) else { throw RenderError.nothingToSay }
            return url
        }
    }

    /// Where this reading's file is, or will be. Pure: no disk access.
    public func fileURL(for reading: WrittenMarginReading) -> URL {
        let seed = ["written-margin-reading-v1", voiceIdentifier ?? "default", reading.spokenText].joined(separator: "\u{1f}")
        return directory.appending(path: "\(Self.fingerprint(seed)).caf", directoryHint: .notDirectory)
    }

    /// A stable 128-bit name from two FNV-1a runs with different starting values, plus the length. Plain arithmetic on
    /// the words in memory: naming a file never reads the disk, so the main thread can ask for a path.
    static func fingerprint(_ seed: String) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x84222325_cbf29ce4
        var count: UInt64 = 0
        for byte in seed.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 &+ count
            count += 1
        }
        return String(format: "%016llx%016llx-%llx", a, b, count)
    }

    /// Whether this reading's file is known to be on disk. Answered from memory, so it is safe on the main thread; false
    /// until a render or a check (`start`, `rendered`) has found the file.
    public func isReady(_ reading: WrittenMarginReading) -> Bool {
        let path = fileURL(for: reading).path
        return lock.withLock { ready.contains(path) }
    }

    /// Names each reading's file and starts rendering the ones that are not on disk yet, off the calling thread. Returns
    /// at once with the paths, keyed as the caller keyed the readings; a file may not exist yet when this returns.
    public func start(_ readings: [String: WrittenMarginReading]) -> [String: URL] {
        var urls: [String: URL] = [:]
        for (key, reading) in readings {
            urls[key] = fileURL(for: reading)
            ensureRendered(reading) { _ in }
        }
        return urls
    }

    /// The reading's file once it is on disk: already there, or rendered now. Never blocks the caller's thread. Throws
    /// `RenderError.timedOut` when the render outlasts its limit.
    public func rendered(_ reading: WrittenMarginReading) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ensureRendered(reading) { continuation.resume(with: $0) }
        }
    }

    /// Returns when every reading is on disk or has failed, or after `limit` seconds, whichever is first. Starts any
    /// render that has not started. Never throws: the caller goes on and the conductor reports a file that is missing.
    public func waitUntilSettled(_ readings: [WrittenMarginReading], upTo limit: TimeInterval) async {
        guard !readings.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once { continuation.resume() }
            let remaining = Counter(readings.count)
            for reading in readings {
                ensureRendered(reading) { _ in if remaining.decrement() == 0 { once.fire() } }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { once.fire() }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        private let action: @Sendable () -> Void
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
        func fire() {
            let first = lock.withLock { () -> Bool in defer { fired = true }; return !fired }
            if first { action() }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ value: Int) { self.value = value }
        func decrement() -> Int { lock.withLock { value -= 1; return value } }
    }

    private func ensureRendered(_ reading: WrittenMarginReading, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let target = fileURL(for: reading)
        lock.lock()
        if waiting[target.path] != nil {
            waiting[target.path]?.append(completion) // the same words are already being rendered: share that render
            lock.unlock()
            return
        }
        waiting[target.path] = [completion]
        pending.append(Job(reading: reading, target: target))
        lock.unlock()
        pump()
    }

    /// Starts the next waiting render when the lane is free. One render at a time, as the other speech renders do; a
    /// lane whose render timed out is given up, so a stuck write never holds back the readings behind it.
    private func pump() {
        lock.lock()
        guard !laneBusy, !pending.isEmpty else { lock.unlock(); return }
        let job = pending.removeFirst()
        laneBusy = true
        let myLane = lane
        lock.unlock()

        let limit = timeLimit(job.reading.spokenText)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result<URL, Error> { try render(job.reading, to: job.target) }
            lock.lock()
            if lane == myLane { laneBusy = false }
            if case .success = result { ready.insert(job.target.path) }
            lock.unlock()
            finish(job, result)
            pump()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { [self] in
            lock.lock()
            let stuck = !job.finished
            if stuck, lane == myLane { lane += 1; laneBusy = false } // give up on this lane; the next render starts fresh
            lock.unlock()
            guard stuck else { return }
            finish(job, .failure(RenderError.timedOut))
            pump()
        }
    }

    /// Hands the result to everyone waiting on the job, once. A render that finishes after its time ran out has already
    /// been answered; its file is still kept, so the next ask finds it.
    private func finish(_ job: Job, _ result: Result<URL, Error>) {
        lock.lock()
        guard !job.finished else { lock.unlock(); return }
        job.finished = true
        let done = waiting.removeValue(forKey: job.target.path) ?? []
        lock.unlock()
        done.forEach { $0(result) }
    }

    private func render(_ reading: WrittenMarginReading, to target: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { return target }
        let scratch = directory.appending(path: "scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let rendered = try renderAudio(reading.spokenText, scratch)
        if fileManager.fileExists(atPath: target.path) { return target } // another render of these words got there first
        try fileManager.moveItem(at: rendered, to: target)
        lock.withLock { _ = ready.insert(target.path) }
        return target
    }
}
#endif
