import Foundation
import SessionKit
import SessionKitAudio
import UIKit

/// Shorter pauses for spoken notes (#4779): the listener's one choice for the app, and the job that makes a note's
/// version. The job runs off the main actor (`SpokenNoteCleanPipeline`), one note at a time, newest first. When a
/// version is ready and the note is the open session, it moves the note onto that file at the same moment
/// (`Gate1AppModel.switchSpokenNoteVersion`); a move held by a recording, a skim or the app being in the background
/// waits and is tried again when that clears. Nothing here plays audio or writes the takes.
@MainActor
final class SpokenNoteCleanCoordinator: ObservableObject {
    @Published private(set) var version: SpokenNoteAudioVersion
    /// By note id, for a note whose version was asked for this launch.
    @Published private(set) var states: [String: SpokenNoteCleanState] = [:]
    /// The note screen records a take: set by that screen, read by the version-change block.
    @Published var takeIsRecording = false
    /// A start of a note the Play path has already given the chosen version, so `startItem` lets it through once.
    var routingItemId: String?

    private let defaults: UserDefaults
    private var job: (id: UUID, noteId: String, work: Task<Result<(SpokenNoteCleanLayout, Int), Error>, Never>)?
    private var pendingStart: (itemId: String, ms: Int)?
    /// A note waiting for the phone to cool, or for the app to come back after the system stopped its export.
    private var waitingNoteId: String?
    /// A move of the open note onto the chosen version, held until nothing blocks it.
    private var pendingMoveNoteId: String?
    private var moveRetry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private weak var app: Gate1AppModel?
    /// Names the step for the hang probe when one of this coordinator's tasks holds the main thread (#2255).
    private static let labels = MainThreadOperationLabels.shared
    /// Starts routed from `startItem` through the Play path (the Library's Continue, a relaunch).
    private let routedPlay = SpokenNoteWholePlayModel()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.version = SpokenNoteAudioVersion.stored(in: defaults)
    }

    func attach(_ app: Gate1AppModel) {
        guard self.app == nil else { return }
        self.app = app
        let center = NotificationCenter.default
        let labels = Self.labels
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in labels.scoped("spokenNoteClean.thermalChanged") { self?.resumeWaiting() } }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                labels.scoped("spokenNoteClean.becameActive") {
                    self?.resumeWaiting()
                    self?.tryPendingMove()
                }
            }
        })
    }

    /// What the control and Now show for a note.
    func state(noteId: String) -> SpokenNoteCleanState {
        version == .asRecorded ? .asRecorded : (states[noteId] ?? .untilPlayed)
    }

    /// The listener chose a version. Choices made quickly one after another end on the last one: each move re-reads
    /// the choice before it restarts anything.
    func choose(_ chosen: SpokenNoteAudioVersion, playingNoteId: String?) {
        guard chosen != version else { return }
        version = chosen
        chosen.store(in: defaults)
        pendingMoveNoteId = nil
        switch chosen {
        case .asRecorded:
            cancelJob() // the job stops; what it made so far stays for next time
            waitingNoteId = nil
            if let playingNoteId { requestMove(noteId: playingNoteId) }
        case .shorterPauses:
            if let playingNoteId { makeVersion(noteId: playingNoteId) }
        }
    }

    /// A note started playing. With Shorter pauses chosen, its version is made (or found made) and moved to.
    func notePlaybackStarted(noteId: String) {
        guard version == .shorterPauses else { return }
        if case .ready = states[noteId] { return }
        makeVersion(noteId: noteId)
    }

    func tryAgain(noteId: String) {
        states[noteId] = nil
        makeVersion(noteId: noteId)
    }

    /// The start time for the next session of `itemId`, set by a version change; read once.
    func takePendingStartMs(itemId: String) -> Int {
        guard let pending = pendingStart, pending.itemId == itemId else { return 0 }
        pendingStart = nil
        return pending.ms
    }

    func setPendingStart(itemId: String, ms: Int) {
        pendingStart = (itemId, ms)
    }

    /// A start from `startItem` for a note whose item names the version not chosen: played through the Play path.
    func routeStart(noteId: String, itemId: String, app: Gate1AppModel) {
        // A note that can't be got ready goes on with the file its item names, as the start did before it was routed.
        routedPlay.play(noteId: noteId, app: app, ifNotReady: { [weak app] in
            guard let app else { return }
            app.spokenNoteClean.routingItemId = itemId
            app.startItem(id: itemId)
        })
    }

    // MARK: Moving the open note

    private func requestMove(noteId: String) {
        pendingMoveNoteId = noteId
        tryPendingMove()
    }

    private func tryPendingMove() {
        guard let noteId = pendingMoveNoteId, let app else { return }
        guard app.spokenNoteIsOpenSession(noteId: noteId) || app.spokenNoteVersionChangeIsBlocked else {
            pendingMoveNoteId = nil // the note isn't playing now: its next start attaches the chosen version
            return
        }
        // A move while the app is in the background would restart what the listener hears with no one looking.
        guard UIApplication.shared.applicationState == .active else { return }
        let target = version
        Task {
            let outcome = await app.switchSpokenNoteVersion(noteId: noteId, to: target)
            guard pendingMoveNoteId == noteId else { return }
            Self.labels.scoped("spokenNoteClean.moveOutcome") {
                switch outcome {
                case .settled:
                    pendingMoveNoteId = nil
                    moveRetry?.cancel()
                    moveRetry = nil
                case .blocked:
                    scheduleMoveRetry()
                }
            }
        }
    }

    /// A blocked move is tried again every second while it waits; recordings and skims end at the listener's pace, and
    /// nothing here is told when, so it looks again.
    private func scheduleMoveRetry() {
        guard moveRetry == nil else { return }
        moveRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.moveRetry = nil
            Self.labels.scoped("spokenNoteClean.moveRetry") { self.tryPendingMove() }
        }
    }

    // MARK: The job

    private static var isHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func resumeWaiting() {
        guard let noteId = waitingNoteId, version == .shorterPauses else { return }
        if Self.isHot { return }
        if UIApplication.shared.applicationState != .active, app?.snapshot.status.isPlaybackActive != true { return }
        waitingNoteId = nil
        makeVersion(noteId: noteId)
    }

    private func cancelJob() {
        job?.work.cancel()
        job = nil
    }

    private func makeVersion(noteId: String) {
        if let running = job {
            if running.noteId == noteId { return }
            cancelJob() // newest first; the cancelled job stops at its next step and removes its half-made file
        }
        if Self.isHot {
            states[noteId] = .hot
            waitingNoteId = noteId
            return
        }
        guard let app, let support = try? app.applicationSupportDirectory(),
              let noteStore = SpokenNoteStarter.store(noteId: noteId, in: support) else {
            states[noteId] = .failed(.other)
            return
        }
        let folder = noteStore.folderURL
        states[noteId] = .making(fraction: 0)
        let id = UUID()
        // Held here so a cancel reaches the pipeline itself, not a task that only waits on it.
        let work = Task.detached(priority: .utility) { () -> Result<(SpokenNoteCleanLayout, Int), Error> in
            do {
                guard let recorded = SpokenNoteWholePlayback.recordedLayout(inFolder: folder) else {
                    throw SpokenNoteWholePlayback.PrepareError.noAudio
                }
                let layout = try await SpokenNoteCleanPipeline().run(requested: recorded.requested, noteFolder: folder) { fraction in
                    Task { @MainActor in self.progress(jobId: id, noteId: noteId, fraction: fraction) }
                }
                return .success((layout, recorded.durationMs))
            } catch {
                return .failure(error)
            }
        }
        job = (id, noteId, work)
        // The coordinator lives as long as the app model, and is main-actor isolated, so the wait holds it plainly.
        Task {
            let outcome = await work.value
            Self.labels.scoped("spokenNoteClean.finished") { self.finished(jobId: id, noteId: noteId, outcome: outcome) }
        }
    }

    private func progress(jobId: UUID, noteId: String, fraction: Double) {
        guard job?.id == jobId, case .making(let shown) = states[noteId], fraction > shown else { return }
        states[noteId] = .making(fraction: fraction)
    }

    private func finished(jobId: UUID, noteId: String, outcome: Result<(SpokenNoteCleanLayout, Int), Error>) {
        guard job?.id == jobId else { return } // a cancelled job's late answer is not this note's state
        job = nil
        switch outcome {
        case .success(let (layout, recordedMs)):
            if layout.result == .interrupted {
                // The system stopped the export in the background: not a failure. It starts again with the app in front.
                waitingNoteId = noteId
                return
            }
            states[noteId] = SpokenNoteCleanState.from(result: layout.result, recordedMs: recordedMs, versionMs: layout.durationMs)
            if layout.result.hasAudio, version == .shorterPauses { requestMove(noteId: noteId) }
        case .failure(let error):
            if error is CancellationError { states[noteId] = nil; return }
            states[noteId] = .failed(.other)
        }
    }
}
