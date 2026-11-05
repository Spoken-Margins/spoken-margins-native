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

    private var environment: SpokenNoteRecorderEnvironment?
    private var coordinator: SpokenNoteRecordingCoordinator?
    private var clock: Task<Void, Never>?
    private var takeStartedAt: Date?
    /// Keeps the app running while a transcript is being made after a take ends (the phone may be locked by then).
    private var endBackgroundWork: (@MainActor () -> Void)?

    func attach(_ environment: SpokenNoteRecorderEnvironment?) {
        guard self.environment == nil else { return }
        self.environment = environment
        if environment == nil { message = "The Library isn't ready yet. Try again in a moment." }
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }

    func record() {
        guard phase == .idle, let environment else { return }
        phase = .starting
        message = nil
        Task { await begin(environment) }
    }

    func stop() {
        guard phase == .recording else { return }
        Task { await stopTake() }
    }

    func retryTranscript(forTake takeId: String) {
        guard let coordinator else { return }
        Task { await coordinator.retryTranscript(forTake: takeId) }
    }

    /// Stops a take that is running, then lets the Library show the note. A transcript still being made carries on
    /// after the screen is gone.
    func finish() async {
        if phase == .recording { await stopTake() }
        guard let environment else { return }
        if let coordinator {
            await coordinator.flushItem()
            let endWork = environment.beginBackgroundWork("Spoken note transcript")
            let libraryChanged = environment.libraryChanged
            Task {
                await coordinator.waitForTranscripts()
                libraryChanged()
                endWork()
            }
        }
        environment.libraryChanged()
    }

    // MARK: Steps

    private func begin(_ environment: SpokenNoteRecorderEnvironment) async {
        guard await environment.requestMicrophone() else {
            phase = .idle
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
        } catch {
            phase = .idle
            message = "Couldn't start recording. Another app or a call may be using the microphone."
        }
    }

    private func ensureCoordinator(_ environment: SpokenNoteRecorderEnvironment) async throws -> SpokenNoteRecordingCoordinator {
        if let coordinator { return coordinator }
        let started = try SpokenNoteStarter.start(in: environment.applicationSupport, now: Date())
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store,
            item: started.item,
            itemIsSaved: false,
            recorder: SystemSpokenNoteTakeRecorder(),
            transcriber: SystemSpokenNoteTranscriber(),
            itemWriter: environment.itemWriter
        )
        await coordinator.setOnChange { [weak self] report in
            Task { @MainActor in self?.apply(report) }
        }
        self.coordinator = coordinator
        return coordinator
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
