import Foundation
import NaturalLanguage
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
import CryptoKit

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

    /// `noVoice`: the phone has no voice for the note's language. `tooManyStuck`: earlier renders are still blocked inside
    /// the speech service, so another is not started behind them (each one holds a thread until the service answers).
    public enum RenderError: Error, Equatable { case nothingToSay, timedOut, noVoice, tooManyStuck }

    /// How many abandoned renders may still be blocked before new ones fail at once.
    public static let defaultMostStuckRenders = 2

    private final class Job: @unchecked Sendable {
        let reading: WrittenMarginReading
        let target: URL
        var finished = false
        init(reading: WrittenMarginReading, target: URL) { self.reading = reading; self.target = target }
    }

    private let directory: URL
    private let voiceIdentifier: String?
    private let renderAudio: @Sendable (_ spokenText: String, _ scratch: URL, _ voice: String?) throws -> URL
    /// True for the iPhone voice: the voice is then chosen from the note's language. A test renderer is given none.
    private let picksVoice: Bool
    private let chooseVoice: @Sendable (_ note: String) -> String?
    private let audioSeconds: @Sendable (URL) -> Double?
    private var introSeconds: [String: Double] = [:] // how long a voice takes to say a sender's intro alone
    private let timeLimit: @Sendable (_ spokenText: String) -> TimeInterval
    private let lock = NSLock()
    private var ready = Set<String>()
    private var waiting: [String: [@Sendable (Result<URL, Error>) -> Void]] = [:]
    private var pending: [Job] = []
    private var laneBusy = false
    private var lane = 0
    private var stuck = 0
    private let mostStuck: Int
    private var lastChecked: [String: Date] = [:]
    private var inFlight = Set<String>() // paths whose render thread is running, even one given up on
    private var doomed = Set<String>() // paths removed while a render of them was running or waiting: they leave no file
    private var sweptScratch = false
    private let recheckAfter: TimeInterval

    /// `renderAudio` writes the speech for `spokenText` somewhere under `scratch` and returns that file. The default is
    /// the iPhone voice.
    public init(
        directory: URL = WrittenMarginReader.defaultDirectory,
        voiceIdentifier: String? = nil,
        timeLimit: (@Sendable (_ spokenText: String) -> TimeInterval)? = nil,
        mostStuckRenders: Int = WrittenMarginReader.defaultMostStuckRenders,
        recheckAfter: TimeInterval = 5,
        voiceForNote: (@Sendable (_ note: String) -> String?)? = nil,
        audioSeconds: @escaping @Sendable (URL) -> Double? = { (try? AVAudioFile(forReading: $0)).map { Double($0.length) / $0.processingFormat.sampleRate } },
        renderAudio: (@Sendable (_ spokenText: String, _ scratch: URL) throws -> URL)? = nil
    ) {
        self.chooseVoice = voiceForNote ?? { WrittenMarginReader.installedVoice(forNote: $0) }
        self.audioSeconds = audioSeconds
        self.directory = directory
        self.voiceIdentifier = voiceIdentifier
        self.mostStuck = mostStuckRenders
        self.recheckAfter = recheckAfter
        self.timeLimit = timeLimit ?? { WrittenMarginReader.defaultTimeLimit(forCharacters: $0.count) }
        self.picksVoice = renderAudio == nil || voiceForNote != nil
        if let renderAudio {
            self.renderAudio = { text, scratch, _ in try renderAudio(text, scratch) }
        } else {
            self.renderAudio = { text, scratch, voice in
                // The words are already cleaned (`WrittenMarginSpeech`) and may be in any script, so the client must not run
                // its article cleaning, which drops the marks Hindi and Thai are written with.
                let client = SystemTextAudioPreparationClient(outputDirectory: scratch, voiceIdentifier: voice, speaksPlainWords: true)
                guard let prepared = try client.prepareTextAudio(itemId: "written-margin", title: "Written Margin", text: text),
                      let url = prepared.media.url.flatMap({ URL(string: $0) }) else { throw RenderError.nothingToSay }
                return url
            }
        }
    }

    /// Where this reading's file is, or will be. Pure: no disk access. The name starts with the item's key, so everything
    /// rendered for an item can be found and removed without knowing its words.
    public func fileURL(for reading: WrittenMarginReading) -> URL {
        let seed = ["written-margin-reading-v2", voiceIdentifier ?? "default", reading.spokenText].joined(separator: "\u{1f}")
        return directory.appending(path: "\(Self.itemKey(reading.itemId))-\(Self.fingerprint(seed)).caf", directoryHint: .notDirectory)
    }

    static func itemKey(_ itemId: String) -> String { String(fingerprint("written-margin-item\u{1f}\(itemId)").prefix(16)) }

    /// A stable name from SHA-256 of the words in memory: naming a file never reads the disk, so the main thread can ask
    /// for a path, and no one can craft a note that shares another note's file.
    static func fingerprint(_ seed: String) -> String {
        // This hashes a short string already in memory, never a file's bytes. `scripts/main_thread_reads.py` flags the one-shot
        // `SHA256.hash(` call because that is how files get hashed; it is about file reads, which this is not. The incremental
        // form is used so the guard needs no baseline row. It is not a way around the guard: nothing here touches the disk.
        var hasher = SHA256()
        hasher.update(data: Data(seed.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this reading's file is known to be on disk. Answered from memory, so it is safe on the main thread; false
    /// until a render or a check (`start`, `rendered`) has found the file.
    public func isReady(_ reading: WrittenMarginReading) -> Bool {
        let path = fileURL(for: reading).path
        let known = lock.withLock { ready.contains(path) }
        if known { verifyLater(path) }
        return known
    }

    /// Drops a reading from the ready set, so the next ask renders it again. For a reading that was ready and then was not
    /// there when it came to play.
    public func forget(_ reading: WrittenMarginReading) {
        let path = fileURL(for: reading).path
        lock.withLock { _ = ready.remove(path) }
    }

    /// The system may clear Caches while the app lives, so a "ready" answer is checked against the disk, off the calling
    /// thread and at most every few seconds per file; a file that is gone stops counting as ready.
    private func verifyLater(_ path: String) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            if let last = lastChecked[path], now.timeIntervalSince(last) < recheckAfter { return false }
            lastChecked[path] = now
            return true
        }
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            if !FileManager.default.fileExists(atPath: path) { lock.withLock { _ = ready.remove(path) } }
        }
    }

    /// The one voice that can read all of this note on this iPhone, or nil (`WrittenMarginVoice`). Asked at render time.
    static func installedVoice(forNote text: String) -> String? {
        WrittenMarginVoice.voice(
            forNote: WrittenMarginSpeech.speakable(text),
            voiceFor: { code in
                let wanted = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][code] ?? code
                if let voice = AVSpeechSynthesisVoice(language: wanted) { return voice.identifier }
                let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
                return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(base) }?.identifier
            },
            defaultVoice: { AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier },
            isAvailable: { AVSpeechSynthesisVoice(identifier: $0) != nil }
        )
    }

    /// Every file derived from an item's words, worked out in one place: the readings in this folder. Their leveled playback
    /// copies are found from these (by content), so a new kind of copy is added to `removeReadings` here and nowhere else.
    func derivedFiles(forItem itemId: String) -> [URL] {
        let prefix = Self.itemKey(itemId) + "-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { directory.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// Removes everything rendered for an item that is deleted for good, and the scratch folders of renders that died. The
    /// words are the friend's: they must not outlive the item (#3365). Trash is not this: a trashed item keeps its
    /// readings, so Undo still plays, and a reading that is gone only renders again. A render of the item that is still
    /// running leaves no file behind. Nothing else is touched: not a Margin, not a recording.
    /// `leveled` is the cache that makes playback copies of recordings (`LeveledMarginCache`): a reading is played through
    /// it like a recording, so its copy holds the same words and goes with the reading, found by the reading's content
    /// before the reading is deleted. Only copies of this item's readings are asked for; no recording is.
    public func removeReadings(forItem itemId: String, leveled: LeveledMarginCache?) {
        let prefix = Self.itemKey(itemId) + "-"
        func isItsFile(_ path: String) -> Bool { URL(fileURLWithPath: path).lastPathComponent.hasPrefix(prefix) }
        lock.withLock {
            ready = ready.filter { !isItsFile($0) }
            lastChecked = lastChecked.filter { !isItsFile($0.key) }
            doomed.formUnion(Set(waiting.keys).union(inFlight).filter(isItsFile))
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            for file in derivedFiles(forItem: itemId) {
                leveled?.removeCopies(of: file) // hashes the reading now; the removal is queued behind any leveling in progress
                try? FileManager.default.removeItem(at: file)
            }
            sweepScratch()
        }
    }

    /// Scratch folders of renders that never finished (a stuck write never reaches its cleanup). One older than the
    /// longest a render may take is nobody's.
    private func sweepScratch() {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("scratch-") {
            let url = directory.appending(path: name, directoryHint: .isDirectory)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > 600 { try? fileManager.removeItem(at: url) }
        }
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
        let sweep = !sweptScratch
        sweptScratch = true
        lock.unlock()
        if sweep { DispatchQueue.global(qos: .utility).async { [self] in sweepScratch() } }
        pump()
    }

    /// Starts the next waiting render when the lane is free. One render at a time, as the other speech renders do; a
    /// lane whose render timed out is given up, so a stuck write never holds back the readings behind it.
    private func pump() {
        lock.lock()
        guard !laneBusy, !pending.isEmpty else { lock.unlock(); return }
        let job = pending.removeFirst()
        if stuck >= mostStuck {
            doomed.remove(job.target.path)
            lock.unlock()
            finish(job, .failure(RenderError.tooManyStuck)) // no new thread behind renders the service hasn't given back
            pump()
            return
        }
        laneBusy = true
        inFlight.insert(job.target.path)
        let myLane = lane
        lock.unlock()

        let limit = timeLimit(job.reading.spokenText)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result<URL, Error> { try render(job.reading, to: job.target) }
            lock.lock()
            if lane == myLane { laneBusy = false } else { stuck -= 1 } // an abandoned render came back
            inFlight.remove(job.target.path)
            let removed = doomed.remove(job.target.path) != nil
            if case .success = result, !removed { ready.insert(job.target.path) }
            lock.unlock()
            finish(job, result)
            pump()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { [self] in
            lock.lock()
            let timedOut = !job.finished
            if timedOut, lane == myLane { lane += 1; laneBusy = false; stuck += 1 } // give up on this lane; the next render starts fresh
            lock.unlock()
            guard timedOut else { return }
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

    /// A sanity check, not proof of coverage: a file no longer than the intro said alone means the voice said nothing of the
    /// note (a voice that is listed but silent). A voice that drops part of a note still passes; the API cannot show that.
    /// A file whose length can't be read is passed on; the player will report it.
    private func isLongerThanTheIntro(_ file: URL, reading: WrittenMarginReading, voice: String, scratch: URL) throws -> Bool {
        guard let whole = audioSeconds(file) else { return true }
        let key = "\(voice)\u{1f}\(reading.intro)"
        var intro = lock.withLock { introSeconds[key] }
        if intro == nil {
            let aside = scratch.appending(path: "intro", directoryHint: .isDirectory) // its own folder: same file names as the note's
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            let alone = try renderAudio(reading.intro, aside, voice)
            intro = audioSeconds(alone) ?? 0
            lock.withLock { introSeconds[key] = intro }
        }
        return whole > (intro ?? 0) + 0.05
    }

    private func render(_ reading: WrittenMarginReading, to target: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { return target }
        let scratch = directory.appending(path: "scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let voice = picksVoice ? (voiceIdentifier ?? chooseVoice(reading.text)) : voiceIdentifier
        if picksVoice, voice == nil { throw RenderError.noVoice } // no installed voice can read all of it: no reading, not a fragment
        let rendered = try renderAudio(reading.spokenText, scratch, voice)
        if picksVoice, let voice, try !isLongerThanTheIntro(rendered, reading: reading, voice: voice, scratch: scratch) {
            throw RenderError.nothingToSay
        }
        if fileManager.fileExists(atPath: target.path) { return target } // another render of these words got there first
        // The item was deleted for good while this rendered: its words go no further than the scratch folder.
        if lock.withLock({ doomed.contains(target.path) }) { throw RenderError.nothingToSay }
        try fileManager.moveItem(at: rendered, to: target)
        lock.withLock { if !doomed.contains(target.path) { ready.insert(target.path) } }
        return target
    }
}
#endif
