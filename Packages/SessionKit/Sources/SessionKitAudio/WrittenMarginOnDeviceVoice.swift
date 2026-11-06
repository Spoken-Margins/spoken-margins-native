import Foundation
import SessionKit

/// Which voice reads a friend's written Margin, once the listener has accepted the Terms (#3391).
///
/// The owner's call (2026-11-02, `docs/decisions.md`): the on-device voice reads it aloud, and before the Terms are
/// accepted the app reads with the iPhone voice, as the Terms gate already does for everything else. This type is only
/// the decision. It is pure, so every case is a host test; the app supplies the facts it can read in memory.
public enum WrittenMarginVoiceChoice: Equatable, Sendable {
    /// The iPhone voice, and why the listener's own voice is not used.
    case iPhone(Reason)
    /// The listener's chosen on-device voice. `key` names it in the reading's file name, so a reading of another voice
    /// is never played for this one.
    case onDevice(key: String)

    public enum Reason: Equatable, Sendable {
        case termsNotAccepted
        /// No on-device voice is chosen (the iPhone voice or Kitten is), or this build has no renderer for the one that is.
        case noSelection
        /// The chosen voice's files are not on the phone (never downloaded, or removed).
        case voiceMissing
        /// Heat, memory or power say the voice must not render now.
        case notAllowedNow
    }

    /// The chosen on-device voice, as the app can see it without touching the disk.
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let isInstalled: Bool
        public let allowedNow: Bool
        public init(key: String, isInstalled: Bool, allowedNow: Bool) {
            self.key = key
            self.isInstalled = isInstalled
            self.allowedNow = allowedNow
        }
    }

    /// The Terms come first: without them nothing about the on-device voice is even looked at.
    public static func choose(termsAccepted: Bool, candidate: Candidate?) -> WrittenMarginVoiceChoice {
        guard termsAccepted else { return .iPhone(.termsNotAccepted) }
        guard let candidate else { return .iPhone(.noSelection) }
        guard candidate.isInstalled else { return .iPhone(.voiceMissing) }
        guard candidate.allowedNow else { return .iPhone(.notAllowedNow) }
        return .onDevice(key: candidate.key)
    }

    /// The on-device voices speak English. A note with letters of another script, or that is plainly in another
    /// language, goes to the iPhone voice, which picks a voice for its language (`WrittenMarginVoice`).
    public static func onDeviceCanRead(_ note: String) -> Bool {
        let speakable = WrittenMarginSpeech.speakable(note)
        guard WrittenMarginVoice.nonLatinScripts(in: speakable).isEmpty else { return false }
        return WrittenMarginVoice.isEnglishOrUndetermined(speakable)
    }
}

/// Raised by the listener's skip: the render is stopped at its next step. It never falls back to the iPhone voice.
public final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

/// The on-device voice's part of a reading: tried first, under a time budget, and given up on for the iPhone voice.
public struct WrittenMarginOnDeviceStage: Sendable {
    /// Names the voice in the reading's file name (`WrittenMarginVoiceChoice.onDevice`).
    public let key: String
    /// How long the on-device voice may take before the iPhone voice reads instead.
    ///
    /// 5 seconds. The evidence: a Core ML voice's first render loads and specialises its models and took over 15 s
    /// (#2856, `Gate1AppModel+AudioClients.swift`), so a cold voice never makes it and must give way quickly; a warm one
    /// only runs inference, which a short note (a sentence or two) finishes well inside this. "Hear only the Margins"
    /// holds off for 10 s for its readings (`WrittenMarginReadings.reviewHold`), so budget plus the iPhone voice's own
    /// render (about a second or two) fits inside it. Not measured on a phone for each voice: unchecked, and the
    /// reason T3 and the owner's phone must see a real render.
    public static let defaultBudget: TimeInterval = 5

    public let budget: TimeInterval
    /// Whether the on-device voice reads this note (see `WrittenMarginVoiceChoice.onDeviceCanRead`).
    public let reads: @Sendable (_ note: String) -> Bool
    /// Writes the speech for `text` under `scratch` and returns the file. Runs on a background thread, once at a time.
    /// It should stop promptly when `cancel` is cancelled, and must throw when the voice cannot read.
    public let render: @Sendable (_ text: String, _ scratch: URL, _ cancel: RenderCancellation) throws -> URL
    /// "May this voice render now?", asked on the render's background thread just before it starts (it may read the disk
    /// and the heat, memory and power governor). False hands the reading to the iPhone voice, for every voice alike: the
    /// same block the player obeys (`OnDeviceVoiceEngine.renderingAllowed`), so a hot or low-memory phone is never asked
    /// for more than the player would ask (#3391). A missing voice is false here too.
    public let isAllowed: @Sendable () -> Bool

    public init(
        key: String,
        budget: TimeInterval = WrittenMarginOnDeviceStage.defaultBudget,
        reads: @escaping @Sendable (_ note: String) -> Bool = WrittenMarginVoiceChoice.onDeviceCanRead,
        isAllowed: @escaping @Sendable () -> Bool = { true },
        render: @escaping @Sendable (_ text: String, _ scratch: URL, _ cancel: RenderCancellation) throws -> URL
    ) {
        self.key = key
        self.budget = budget
        self.reads = reads
        self.render = render
        self.isAllowed = isAllowed
    }
}

/// Runs the on-device attempt for a reading: off the caller's thread, bounded, one at a time.
final class WrittenMarginOnDeviceRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = 0

    /// How many attempts were given up on but are still running (each still holds the voice's model).
    var stillRunning: Int { lock.withLock { abandoned } }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<URL, Error>?
        var abandoned = false
    }

    /// The file the on-device voice made, or nil when the iPhone voice should read: the note is one it can't read, the
    /// render failed or ran out of its budget, an earlier attempt is still holding the voice, or it made nothing.
    /// Throws `CancellationError` when `cancel` was cancelled: the listener moved on, so nothing else is rendered.
    func attempt(_ stage: WrittenMarginOnDeviceStage, text: String, note: String, scratch: URL, cancel: RenderCancellation) throws -> URL? {
        if cancel.isCancelled { throw CancellationError() }
        guard stage.reads(note) else { return nil }
        guard stillRunning == 0 else { return nil } // never a second copy of the voice's models beside a late render
        guard stage.isAllowed() else { return nil } // hot, short of memory, or the voice is gone: the iPhone voice reads
        let folder = scratch.appending(path: "on-device", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let own = RenderCancellation()
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result<URL, Error> { try stage.render(text, folder, own) }
            let late = box.lock.withLock { () -> Bool in
                box.result = result
                return box.abandoned
            }
            if late {
                // Nobody will play this: it was given up on or skipped. It holds the friend's words, so it goes now.
                if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
                lock.withLock { abandoned -= 1 }
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(stage.budget)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancel.isCancelled { own.cancel(); discardIfFinished(box); throw CancellationError() }
            if Date() >= deadline { own.cancel(); discardIfFinished(box); return nil }
        }
        if cancel.isCancelled {
            if case .success(let file)? = box.lock.withLock({ box.result }) { try? FileManager.default.removeItem(at: file) }
            throw CancellationError()
        }
        guard case .success(let file)? = box.lock.withLock({ box.result }), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }

    /// Gives up on a render still running (it is deleted when it comes back), or, if it finished in the meantime, deletes
    /// what it made.
    private func discardIfFinished(_ box: Box) {
        let made = box.lock.withLock { () -> Result<URL, Error>? in
            if box.result == nil { box.abandoned = true }
            return box.result
        }
        guard let made else { lock.withLock { abandoned += 1 }; return }
        if case .success(let file) = made { try? FileManager.default.removeItem(at: file) }
    }
}
