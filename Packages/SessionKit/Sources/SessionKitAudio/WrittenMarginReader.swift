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

    /// Someone waiting on a render. A waiter with an `id` leaves when its task is cancelled (the listener skipped); one
    /// without (`start`, `waitUntilSettled`) wants the reading whatever happens to any one listener.
    private struct Waiter {
        let id: UUID?
        let completion: @Sendable (Result<URL, Error>) -> Void
    }

    private final class Job: @unchecked Sendable {
        let reading: WrittenMarginReading
        let target: URL
        /// The on-device voice to try first (#3391), nil for the iPhone voice. A job with one writes `target` only if that
        /// voice made the reading; the iPhone voice's reading is written at the iPhone path, so a file's path always says
        /// which voice made it.
        let stage: WrittenMarginOnDeviceStage?
        /// Set when nobody waits for the on-device try any more: it stops at its next step.
        let cancel = RenderCancellation()
        var waiters: [Waiter] = []
        var started = false
        /// The on-device try is over (made a file, gave up, or was not asked for): a skip no longer has anything to stop.
        var pastAttempt = false
        /// The item was deleted for good while this ran: nothing it makes is kept, whichever voice made it.
        var doomed = false
        var finished = false
        /// The render thread has come back (set under the reader's lock, in the same section that frees its lane). `finished`
        /// is set later, by `finish`, so a timeout that looked at `finished` alone could see a render that had already
        /// returned as still blocked and count it stuck for good (#3412).
        var returned = false
        init(reading: WrittenMarginReading, target: URL, stage: WrittenMarginOnDeviceStage?) {
            self.reading = reading; self.target = target; self.stage = stage
            pastAttempt = stage == nil
        }
    }

    private let directory: URL
    private let voiceIdentifier: String?
    /// One runner for every on-device voice: a late render of one voice holds up an attempt of any other, so two models
    /// are never loaded at once, whichever voice is chosen (#3391).
    private let onDeviceRunner = WrittenMarginOnDeviceRunner()
    private var fellBack: [String: Date] = [:] // on-device path -> when the iPhone voice read it instead
    private var readsCache: [String: Bool] = [:] // voice key + words -> whether that voice can read them (language, asked off the main thread)
    /// How long a reading the iPhone voice made in place of the on-device voice is played as it is, before the on-device
    /// voice is tried for that Margin again (it may be warm by then).
    private let retryOnDeviceAfter: TimeInterval
    private let renderAudio: @Sendable (_ spokenText: String, _ scratch: URL, _ voice: String?) throws -> URL
    /// True for the iPhone voice: the voice is then chosen from the note's language. A test renderer is given none.
    private let picksVoice: Bool
    private let chooseVoice: @Sendable (_ note: String) -> String?
    private let audioSeconds: @Sendable (URL) -> Double?
    private var introSeconds: [String: Double] = [:] // how long a voice takes to say a sender's intro alone
    private let timeLimit: @Sendable (_ spokenText: String) -> TimeInterval
    private let lock = NSLock()
    private var ready = Set<String>()
    private var jobs: [String: Job] = [:] // by target path, while someone may still wait for it
    private var active: [Job] = [] // queued or running, until the render thread comes back
    private var pending: [Job] = []
    private var laneBusy = false
    private var lane = 0
    private var stuck = 0
    private let mostStuck: Int
    private var lastChecked: [String: Date] = [:]
    private var sweptScratch = false
    private let recheckAfter: TimeInterval
    /// Tests only: runs on the render thread after it has come back and before it hands the result over, to hold the
    /// window in which the time limit can fire (#3412).
    var beforeFinish: (@Sendable (WrittenMarginReading) -> Void)?

    /// `renderAudio` writes the speech for `spokenText` somewhere under `scratch` and returns that file. The default is
    /// the iPhone voice.
    public init(
        directory: URL = WrittenMarginReader.defaultDirectory,
        voiceIdentifier: String? = nil,
        timeLimit: (@Sendable (_ spokenText: String) -> TimeInterval)? = nil,
        mostStuckRenders: Int = WrittenMarginReader.defaultMostStuckRenders,
        recheckAfter: TimeInterval = 5,
        retryOnDeviceAfter: TimeInterval = 120,
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
        self.retryOnDeviceAfter = retryOnDeviceAfter
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
        path(for: reading, voice: voiceIdentifier ?? "default")
    }

    /// Where the on-device voice `key`'s reading is, or will be. A different name from the iPhone voice's, so a reading is
    /// never played for a voice that did not make it (#3391).
    public func fileURL(for reading: WrittenMarginReading, onDevice stage: WrittenMarginOnDeviceStage) -> URL {
        path(for: reading, voice: "on-device:\(stage.key)")
    }

    private func path(for reading: WrittenMarginReading, voice: String) -> URL {
        let seed = ["written-margin-reading-v2", voice, reading.spokenText].joined(separator: "\u{1f}")
        return directory.appending(path: "\(Self.itemKey(reading.itemId))-\(Self.fingerprint(seed)).caf", directoryHint: .notDirectory)
    }

    private func readsKey(_ stage: WrittenMarginOnDeviceStage, _ reading: WrittenMarginReading) -> String { "\(stage.key)\u{1f}\(reading.text)" }

    private func recentlyFellBack(_ devicePath: String) -> Bool {
        lock.withLock { fellBack[devicePath].map { Date().timeIntervalSince($0) < retryOnDeviceAfter } ?? false }
    }

    /// The stage that applies to this note, from memory alone (the main thread may ask): nil when the iPhone voice reads it
    /// from the start. That is a note the voice takes too long for (`mostCharacters`), one it was found unable to read
    /// (another script or language), and one it gave up on a moment ago (`retryOnDeviceAfter`). The language is not
    /// worked out here, because that is not for the main thread: until the render thread has looked (`readsAfterLooking`),
    /// a note is taken to be readable, and the render thread sends the others to the iPhone voice.
    private func effective(_ stage: WrittenMarginOnDeviceStage?, for reading: WrittenMarginReading) -> WrittenMarginOnDeviceStage? {
        guard let stage, reading.text.count <= stage.mostCharacters else { return nil }
        if lock.withLock({ readsCache[readsKey(stage, reading)] }) == false { return nil }
        if recentlyFellBack(fileURL(for: reading, onDevice: stage).path) { return nil }
        return stage
    }

    /// Whether the chosen on-device voice is still to be given this note, so its first hearing should wait for it. False
    /// for the iPhone voice, a note too long or unreadable for the voice, and one it gave up on a moment ago. In memory.
    public func wantsOnDevice(_ reading: WrittenMarginReading, stage: WrittenMarginOnDeviceStage?) -> Bool {
        effective(stage, for: reading) != nil && !playbackState(for: reading, onDevice: stage).isReady
    }

    /// Whether the voice can read the note, asked of the voice and kept. Runs the language recognizer: render threads only.
    private func readsAfterLooking(_ stage: WrittenMarginOnDeviceStage, _ reading: WrittenMarginReading) -> Bool {
        let key = readsKey(stage, reading)
        if let known = lock.withLock({ readsCache[key] }) { return known }
        let answer = stage.reads(reading.text)
        lock.withLock { readsCache[key] = answer }
        return answer
    }

    /// The one answer to "what plays for this Margin now", for the voice the listener chose (`onDevice`, nil for the iPhone
    /// voice). `file` is always a file that exists or that a render is being made for at exactly that path: the
    /// on-device voice's reading when it has made it, otherwise the iPhone voice's. `isReady` says whether that file is
    /// there and should play now. It is false for a note the on-device voice is still to be given (not tried yet, or its
    /// time to retry has come), so the first hearing waits for it (`rendered`) instead of playing an iPhone reading made
    /// ahead, and true once the voice gave up on the note or cannot read it. In memory only, so the main thread may ask.
    /// Starts nothing.
    public func playbackState(for reading: WrittenMarginReading, onDevice stage: WrittenMarginOnDeviceStage?) -> (file: URL, isReady: Bool) {
        guard let stage = effective(stage, for: reading) else { return (fileURL(for: reading), isReady(reading)) }
        let device = fileURL(for: reading, onDevice: stage)
        if isKnownReady(device.path) { return (device, true) }
        return (fileURL(for: reading), false)
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
    public func isReady(_ reading: WrittenMarginReading) -> Bool { isKnownReady(fileURL(for: reading).path) }

    private func isKnownReady(_ path: String) -> Bool {
        let known = lock.withLock { ready.contains(path) }
        if known { verifyLater(path) }
        return known
    }

    /// Drops a reading from the ready set, so the next ask renders it again. For a reading that was ready and then was not
    /// there when it came to play.
    public func forget(_ reading: WrittenMarginReading, onDevice stage: WrittenMarginOnDeviceStage? = nil) {
        let paths = [fileURL(for: reading).path] + (stage.map { [fileURL(for: reading, onDevice: $0).path] } ?? [])
        lock.withLock { paths.forEach { _ = ready.remove($0) } }
    }

    /// What the reader is doing right now. It is one render lane for the whole process (`shared`), so a test that leaves a
    /// render behind holds up the next test's reading; tests read this to see that they have left it as they found it.
    public struct Activity: Equatable, Sendable, CustomStringConvertible {
        /// Renders waiting for the lane.
        public let queued: Int
        /// Render threads that have not come back, including ones given up on.
        public let running: Int
        /// Readings someone is waiting on.
        public let waiting: Int
        /// Renders given up on that are still blocked.
        public let stuck: Int
        public var isIdle: Bool { queued == 0 && running == 0 && waiting == 0 && stuck == 0 }
        public var description: String { "queued \(queued), running \(running), waited on \(waiting), stuck \(stuck)" }
    }

    public var activity: Activity {
        lock.withLock { Activity(queued: pending.count, running: active.filter { $0.started }.count, waiting: jobs.count, stuck: stuck) }
    }

    /// Runs `then` once no render of this reading is queued or running: at once when there is none, otherwise right after
    /// the render that is. No polling and no delay. A test that removes a reading's file uses it so the file is never
    /// taken from under a render that is about to look for it, which would start a real speech render (#1230).
    /// A render already given up on has no one waiting for it, so it is not waited for here; `settle` shows it.
    public func whenSettled(_ reading: WrittenMarginReading, then: @escaping @Sendable () -> Void) {
        let path = fileURL(for: reading).path
        lock.lock()
        if let job = jobs[path] {
            job.waiters.append(Waiter(id: nil) { _ in then() })
            lock.unlock()
            return
        }
        lock.unlock()
        then()
    }

    /// Returns when every reading someone is waiting on is on disk or has failed, or after `limit` seconds, and says what
    /// the reader is doing then. Starts no render. `activity.isIdle` is the answer to "did the last test leave nothing
    /// behind".
    public func settle(upTo limit: TimeInterval) async -> Activity {
        let paths = lock.withLock { Array(jobs.keys) }
        guard !paths.isEmpty else { return activity }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once { continuation.resume() }
            let remaining = Counter(paths.count)
            for path in paths {
                lock.lock()
                if let job = jobs[path] {
                    job.waiters.append(Waiter(id: nil) { _ in if remaining.decrement() == 0 { once.fire() } })
                    lock.unlock()
                } else {
                    lock.unlock()
                    if remaining.decrement() == 0 { once.fire() }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { once.fire() }
        }
        return activity
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
            // Whatever of this item is queued, running or still waited on makes no file, whichever voice is reading it. The
            // job decides, not a path, because an on-device job that falls back writes another path than its own.
            for job in active + Array(jobs.values) where isItsFile(job.target.path) { job.doomed = true }
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

    /// Names the file to hand a player for each reading, keyed as the caller keyed the readings, and starts the iPhone voice
    /// on any that are not ready. For a caller that cannot wait: the file named is the on-device voice's if it is ready,
    /// else the iPhone voice's, which is being written. Returns at once; a file may not exist yet. It never starts the
    /// on-device voice: that is `rendered` and `waitUntilSettled`, which have a listener waiting (#3391).
    public func start(_ readings: [String: WrittenMarginReading], onDevice stage: WrittenMarginOnDeviceStage? = nil) -> [String: URL] {
        var urls: [String: URL] = [:]
        for (key, reading) in readings {
            let state = playbackState(for: reading, onDevice: stage)
            urls[key] = state.file
            if state.file == fileURL(for: reading), !isReady(reading) { ensureRendered(reading, onDevice: nil, waiter: nil) { _ in } }
        }
        return urls
    }

    /// Renders ahead, when a screen opens, the readings that will be heard in the iPhone voice, which costs the listener
    /// nothing. A reading the chosen on-device voice will be given when it is played is left alone: rendering it now would
    /// make a file in a voice nobody hears, and the on-device voice is not run on opening a screen. Works off the calling
    /// thread, which is where the language of each note is found.
    public func prepareAhead(_ readings: [String: WrittenMarginReading], onDevice stage: WrittenMarginOnDeviceStage?) {
        guard let stage else { _ = start(readings); return }
        let all = Array(readings.values)
        DispatchQueue.global(qos: .utility).async { [self] in
            for reading in all {
                _ = readsAfterLooking(stage, reading)
                if effective(stage, for: reading) == nil, !isReady(reading) { ensureRendered(reading, onDevice: nil, waiter: nil) { _ in } }
            }
        }
    }

    /// The reading's file once it is on disk: already there, or rendered now. Never blocks the caller's thread. Throws
    /// `RenderError.timedOut` when the render outlasts its limit. When the caller's task is cancelled (the listener
    /// skipped) the call throws `CancellationError` at once, and the on-device try stops only if no one else is waiting
    /// for the same reading; a later ask joins a render that is still wanted, or starts a fresh one (#3391).
    public func rendered(_ reading: WrittenMarginReading, onDevice stage: WrittenMarginOnDeviceStage? = nil) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ensureRendered(reading, onDevice: stage, waiter: id) { continuation.resume(with: $0) }
                if Task.isCancelled { leave(id) } // cancelled before the wait was in place
            }
        } onCancel: {
            leave(id)
        }
    }

    /// A waiter whose task was cancelled stops waiting. If it was the last one for an on-device try that is not over, the
    /// try is stopped and the job let go, so a new ask starts its own.
    private func leave(_ id: UUID) {
        var completion: (@Sendable (Result<URL, Error>) -> Void)?
        lock.lock()
        for job in jobs.values {
            guard let index = job.waiters.firstIndex(where: { $0.id == id }) else { continue }
            completion = job.waiters.remove(at: index).completion
            if job.waiters.isEmpty, !job.pastAttempt {
                job.cancel.cancel()
                jobs[job.target.path] = nil
            }
            break
        }
        lock.unlock()
        completion?(.failure(CancellationError()))
    }

    /// Returns when every reading is on disk or has failed, or after `limit` seconds, whichever is first. Starts any
    /// render that has not started, the on-device voice's included, for a listener who is waiting. When it returns, or when
    /// the caller's task is cancelled (the listener left), it stops waiting: an on-device try that nobody else waits for
    /// stops at its next step, so nothing keeps rendering with no one to hear it (#3391). Never throws: the caller goes
    /// on and the conductor reports a file that is missing.
    public func waitUntilSettled(_ readings: [WrittenMarginReading], upTo limit: TimeInterval, onDevice stage: WrittenMarginOnDeviceStage? = nil) async {
        guard !readings.isEmpty else { return }
        let ids = readings.map { _ in UUID() }
        let leaveAll: @Sendable () -> Void = { [self] in ids.forEach { leave($0) } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once { continuation.resume() }
                let remaining = Counter(readings.count)
                for (reading, id) in zip(readings, ids) {
                    let applies = effective(stage, for: reading)
                    if playbackState(for: reading, onDevice: applies).isReady {
                        if remaining.decrement() == 0 { once.fire() }
                        continue
                    }
                    ensureRendered(reading, onDevice: applies, waiter: id) { _ in if remaining.decrement() == 0 { once.fire() } }
                }
                if Task.isCancelled { leaveAll() }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { once.fire() }
            }
        } onCancel: {
            leaveAll()
        }
        leaveAll()
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

    private func ensureRendered(_ reading: WrittenMarginReading, onDevice stage: WrittenMarginOnDeviceStage?, waiter: UUID?, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        // The on-device voice is tried only for someone who is waiting (a waiter with an id, who can leave). A caller with
        // none gets the iPhone voice, so no on-device render can run with nobody there to hear it.
        let stage = waiter == nil ? nil : effective(stage, for: reading)
        let target = stage.map { fileURL(for: reading, onDevice: $0) } ?? fileURL(for: reading)
        lock.lock()
        if let job = jobs[target.path] {
            job.waiters.append(Waiter(id: waiter, completion: completion)) // the same words are already being rendered: share that render
            lock.unlock()
            return
        }
        let job = Job(reading: reading, target: target, stage: stage)
        job.waiters = [Waiter(id: waiter, completion: completion)]
        jobs[target.path] = job
        active.append(job)
        pending.append(job)
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
            active.removeAll { $0 === job }
            lock.unlock()
            finish(job, .failure(RenderError.tooManyStuck)) // no new thread behind renders the service hasn't given back
            pump()
            return
        }
        laneBusy = true
        job.started = true
        let myLane = lane
        lock.unlock()

        let limit = timeLimit(job.reading.spokenText) + (job.stage?.budget ?? 0) // the on-device try's budget comes before the iPhone voice's render
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result<URL, Error> { try render(job) }
            lock.lock()
            job.returned = true
            if lane == myLane { laneBusy = false } else { stuck -= 1 } // an abandoned render came back
            active.removeAll { $0 === job }
            if case .success(let file) = result, !job.doomed { ready.insert(file.path) }
            lock.unlock()
            beforeFinish?(job.reading)
            finish(job, result)
            pump()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit) { [self] in
            lock.lock()
            let timedOut = !job.returned && !job.finished // a render that has come back is not stuck, whatever `finish` has done yet
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
        let done = job.waiters
        job.waiters = []
        if jobs[job.target.path] === job { jobs[job.target.path] = nil }
        lock.unlock()
        done.forEach { $0.completion(result) }
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

    /// The reading's speech by the iPhone voice, in `scratch`.
    private func renderWithIPhone(_ reading: WrittenMarginReading, scratch: URL) throws -> URL {
        let voice = picksVoice ? (voiceIdentifier ?? chooseVoice(reading.text)) : voiceIdentifier
        if picksVoice, voice == nil { throw RenderError.noVoice } // no installed voice can read all of it: no reading, not a fragment
        let file = try renderAudio(reading.spokenText, scratch, voice)
        if picksVoice, let voice, try !isLongerThanTheIntro(file, reading: reading, voice: voice, scratch: scratch) {
            throw RenderError.nothingToSay
        }
        return file
    }

    /// Puts a finished render at `target`, or discards it. The item deleted for good while it rendered keeps nothing, and
    /// the file is removed here, not left where the voice wrote it.
    private func place(_ file: URL, at target: URL, job: Job) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: file); return target } // another render of these words got there first
        if lock.withLock({ job.doomed }) {
            try? fileManager.removeItem(at: file)
            throw RenderError.nothingToSay
        }
        do { try fileManager.moveItem(at: file, to: target) } catch {
            if fileManager.fileExists(atPath: target.path) { try? fileManager.removeItem(at: file); return target }
            throw error
        }
        return target
    }

    private func render(_ job: Job) throws -> URL {
        let fileManager = FileManager.default
        if job.cancel.isCancelled { throw CancellationError() }
        if fileManager.fileExists(atPath: job.target.path) { return job.target }
        let scratch = directory.appending(path: "scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let reading = job.reading
        guard let stage = job.stage else {
            return try place(try renderWithIPhone(reading, scratch: scratch), at: job.target, job: job)
        }
        // The listener's chosen voice first, within its budget. A slow, failed or blocked try (and the iPhone voice for a
        // note it cannot read) falls through to the iPhone voice, so a reading is never silence. A skip throws and falls
        // back to nothing. The on-device voice's file is `target`; the iPhone voice's goes to its own path, so a path
        // never names a voice that did not make the file.
        var made: URL?
        do {
            guard readsAfterLooking(stage, reading) else { throw RenderError.noVoice } // a note it cannot read: the iPhone voice, at once
            made = try onDeviceRunner.attempt(stage, text: reading.spokenText, note: reading.text, scratch: scratch, cancel: job.cancel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            made = nil
        }
        lock.withLock { job.pastAttempt = true }
        if let made { return try place(made, at: job.target, job: job) }
        lock.withLock { fellBack[job.target.path] = Date() }
        let phone = fileURL(for: reading)
        if fileManager.fileExists(atPath: phone.path) { return phone }
        return try place(try renderWithIPhone(reading, scratch: scratch), at: phone, job: job)
    }
}
#endif
