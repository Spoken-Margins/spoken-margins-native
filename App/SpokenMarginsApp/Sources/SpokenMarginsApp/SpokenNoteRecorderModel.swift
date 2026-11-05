import Foundation
import SessionKit
import SessionKitAudio
import SwiftUI

/// What the spoken note recorder needs from the rest of the app (#3108). Everything it touches comes in here, so
/// `SpokenNoteRecorderModel` holds no reference to `Gate1AppModel`.
struct SpokenNoteRecorderEnvironment {
    var applicationSupport: URL
    /// Writes the note's Library item. Called off the main thread, in order, by the note's coordinator.
    var itemWriter: any SpokenNoteItemWriting
    var requestMicrophone: @MainActor () async -> Bool
    /// Called just before the microphone opens: pauses whatever is playing so it isn't in the recording.
    var prepareToRecord: @MainActor () -> Void
    /// The Library should show the note as it now is.
    var libraryChanged: @MainActor () -> Void
    /// Keeps the app running a little after the screen locks, to finish a transcript. Returns the call that ends it.
    var beginBackgroundWork: @MainActor (String) -> (@MainActor () -> Void)
}

/// A note reopened from its Library row.
struct SpokenNoteOpening: Identifiable, Equatable {
    let noteId: String
    let title: String
    var id: String { noteId }
}

/// The recording screen's state: one spoken note, recorded in takes (#3108, #1609 slice 1).
///
/// The note is started on the first Record tap, not when the screen opens, so opening and closing the screen leaves
/// nothing behind. All the work (files, take order, transcripts, the Library row) is the coordinator's; this type
/// only starts and stops it and shows what it reports.
@MainActor
final class SpokenNoteRecorderModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording, stopping
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var snapshot: SpokenNoteRecordingSnapshot?
    /// Seconds recorded in the take now running.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var message: String?
    /// The note's folder, once it is known (a reopened note's at once; a new note's at its first Record tap).
    @Published private(set) var noteFolder: URL?

    private var environment: SpokenNoteRecorderEnvironment?
    private var coordinator: SpokenNoteRecordingCoordinator?
    private var clock: Task<Void, Never>?
    private var takeStartedAt: Date?
    /// The screen has been closed: nothing may start, and a take that was still starting is stopped at once.
    private var isFinished = false
    /// Keeps the app running while a transcript is being made after a take ends (the phone may be locked by then).
    private var endBackgroundWork: (@MainActor () -> Void)?

    /// - Parameter opening: a note from the Library to show and add to. Its takes are shown at once, and any take
    ///   that has no transcript (the app ended before it finished) is asked for again.
    func attach(_ environment: SpokenNoteRecorderEnvironment?, opening: SpokenNoteOpening? = nil) {
        guard self.environment == nil else { return }
        self.environment = environment
        guard let environment else {
            message = "The Library isn't ready yet. Try again in a moment."
            return
        }
        guard let opening else { return }
        guard let started = SpokenNoteStarter.reopen(
            noteId: opening.noteId, title: opening.title, in: environment.applicationSupport, now: Date()
        ) else {
            message = "This note's recordings aren't on this phone."
            return
        }
        let coordinator = makeCoordinator(started, itemIsSaved: true, environment)
        self.coordinator = coordinator
        noteFolder = started.store.folderURL
        Task {
            await coordinator.setOnChange { [weak self] report in
                Task { @MainActor in self?.apply(report) }
            }
            await coordinator.resumeTranscripts()
        }
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }

    /// - Parameter prepare: Work to finish before the microphone opens (a sentence handing the audio session back).
    ///   The screen is `.starting` from this call on, so while it runs neither Record nor a sentence can be tapped.
    func record(after prepare: (@MainActor () async -> Void)? = nil) {
        guard phase == .idle, !isFinished, let environment else { return }
        phase = .starting
        message = nil
        Task {
            await prepare?()
            await begin(environment)
        }
    }

    func stop() {
        guard phase == .recording else { return }
        Task { await stopTake() }
    }

    /// Pauses whatever the app is playing, so it isn't mixed with a sentence being played from this note.
    func pauseOtherPlayback() {
        environment?.prepareToRecord()
    }

    func retryTranscript(forTake takeId: String) {
        guard let coordinator else { return }
        Task { await coordinator.retryTranscript(forTake: takeId) }
    }

    /// Stops a take that is running, then lets the Library show the note. A transcript still being made carries on
    /// after the screen is gone.
    func finish() async {
        isFinished = true
        if phase == .recording { await stopTake() }
        guard let environment else { return }
        if let coordinator {
            await coordinator.flushItem()
            keepAliveUntilTranscribed(coordinator, environment)
        }
        environment.libraryChanged()
    }

    // MARK: Steps

    /// A transcript still being made carries on after the screen is gone: this holds the coordinator, and a little
    /// background time, until every transcript is back.
    private func keepAliveUntilTranscribed(_ coordinator: SpokenNoteRecordingCoordinator, _ environment: SpokenNoteRecorderEnvironment) {
        let endWork = environment.beginBackgroundWork("Spoken note transcript")
        let libraryChanged = environment.libraryChanged
        Task {
            await coordinator.waitForTranscripts()
            libraryChanged()
            endWork()
        }
    }

    private func begin(_ environment: SpokenNoteRecorderEnvironment) async {
        guard await environment.requestMicrophone(), !isFinished else {
            phase = .idle
            if isFinished { return }
            message = "Allow the microphone for Spoken Margins in Settings to record a spoken note."
            return
        }
        environment.prepareToRecord()
        do {
            let coordinator = try await ensureCoordinator(environment)
            do {
                try await coordinator.startTake()
            } catch {
                // A note that never got a take leaves no folder behind.
                if await coordinator.discardIfNothingWasRecorded() { self.coordinator = nil; self.snapshot = nil }
                throw error
            }
            takeStartedAt = Date()
            elapsed = 0
            phase = .recording
            startClock()
            // The screen was closed while the microphone was opening: keep what it took and stop.
            if isFinished {
                await stopTake()
                keepAliveUntilTranscribed(coordinator, environment)
            }
        } catch {
            phase = .idle
            message = "Couldn't start recording. Another app or a call may be using the microphone."
        }
    }

    private func ensureCoordinator(_ environment: SpokenNoteRecorderEnvironment) async throws -> SpokenNoteRecordingCoordinator {
        if let coordinator { return coordinator }
        let started = try SpokenNoteStarter.start(in: environment.applicationSupport, now: Date())
        let coordinator = makeCoordinator(started, itemIsSaved: false, environment)
        noteFolder = started.store.folderURL
        await coordinator.setOnChange { [weak self] report in
            Task { @MainActor in self?.apply(report) }
        }
        self.coordinator = coordinator
        return coordinator
    }

    private func makeCoordinator(
        _ started: SpokenNoteStarter.Started, itemIsSaved: Bool, _ environment: SpokenNoteRecorderEnvironment
    ) -> SpokenNoteRecordingCoordinator {
        SpokenNoteRecordingCoordinator(
            store: started.store,
            item: started.item,
            itemIsSaved: itemIsSaved,
            recorder: SystemSpokenNoteTakeRecorder(),
            transcriber: SystemSpokenNoteTranscriber(),
            itemWriter: environment.itemWriter
        )
    }

    private func stopTake() async {
        guard let coordinator, phase == .recording else { return }
        phase = .stopping
        stopClock()
        do {
            try await coordinator.stopTake()
        } catch SpokenNoteRecordingCoordinator.RecordingError.notRecording {
            // The system already ended it (a call, say) and the take was closed then.
        } catch {
            message = "Couldn't add this recording to the note yet. The audio is on your phone and is added again on the next try."
        }
        if let environment { holdBackgroundWork(environment) }
        phase = .idle
        environment?.libraryChanged()
    }

    private func apply(_ report: SpokenNoteRecordingSnapshot) {
        guard report.revision >= (snapshot?.revision ?? 0) else { return }
        snapshot = report
        // The system can end a take on its own; the screen goes back to ready.
        if phase == .recording, !report.isRecording {
            stopClock()
            phase = .idle
            message = report.hasUnsavedTake
                ? "Recording stopped. The audio is on your phone and is added to the note on the next try."
                : "Recording stopped. What you said so far is saved."
            if let environment { holdBackgroundWork(environment) }
        }
        // Transcripts being made (a reopened note's, say) keep the app running if the phone locks meanwhile.
        if !report.transcribingTakeIds.isEmpty, let environment { holdBackgroundWork(environment) }
        // The transcripts are done: the app may suspend.
        if report.transcribingTakeIds.isEmpty, !report.isRecording {
            endBackgroundWork?()
            endBackgroundWork = nil
        }
    }

    private func holdBackgroundWork(_ environment: SpokenNoteRecorderEnvironment) {
        guard endBackgroundWork == nil else { return }
        endBackgroundWork = environment.beginBackgroundWork("Spoken note transcript")
    }

    private func startClock() {
        stopClock()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let start = self.takeStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopClock() {
        clock?.cancel()
        clock = nil
    }
}
