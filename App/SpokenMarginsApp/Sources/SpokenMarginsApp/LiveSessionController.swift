import ActivityKit
import Foundation
import SessionKit

/// Drives the live session screen (#1989, #2481): Margins on a clock while something plays or is read outside
/// the app, with nothing recorded. The session is kept in Application Support so closing the app never loses
/// it; Lock Screen Marks arrive through `LiveSessionMarkQueue` and are merged in while the screen is open.
/// Every disk read and write goes through `LiveSessionFileWorker` off the main thread (#2256); the screen keeps
/// the session in memory and only publishes what comes back.
@MainActor
final class LiveSessionController: ObservableObject {
    @Published private(set) var session: LiveSession?
    @Published private(set) var now = Date()
    @Published var errorMessage: String?
    @Published private(set) var isRecordingSpoken = false

    private let files = LiveSessionFileWorker.shared
    /// Rises with each save or discard, so the worker writes them in the order the screen made them.
    private var saveGeneration = 0
    private var spokenStart: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let phoneRecorder = LiveSessionPhoneRecorder()
    private var diskObserver: NSObjectProtocol?

    func load() {
        let generation = saveGeneration
        Task { [weak self, files] in
            let stored = await files.load()
            guard let self else { return }
            // A session started or discarded while the file was read is newer than the file.
            if saveGeneration == generation { session = stored }
            mergeMarks()
            startPolling()
            observeDisk()
            sessionChanged()
            await LiveSessionSpokenMargins.transcribeMissing()
        }
    }

    var isRunning: Bool { session != nil && session?.endedAt == nil }
    var hasEnded: Bool { session?.endedAt != nil }

    var elapsedMs: Int {
        guard let session else { return 0 }
        let end = session.endedAt ?? now
        return max(0, Int((end.timeIntervalSince(session.startedAt) * 1_000).rounded()))
    }

    /// The estimated source position now, "about 1:23:10", when the listener gave a start position.
    func predictedPosition(adjustmentMs: Int = 0) -> LiveSessionPositionMap.Position? {
        guard let session, var position = LiveSessionPositionMap.position(at: now, in: session) else { return nil }
        position.ms = max(0, position.ms + adjustmentMs)
        return position
    }

    func start(kind: ElsewhereKind, title: String, startPositionMs: Int?, startWhere: String?) {
        _ = LiveSessionMarkQueue.drain() // Marks from before this session don't belong to it.
        let started = LiveSession(
            id: "live-\(UUID().uuidString.lowercased())", kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: Date(),
            startPositionMs: startPositionMs, startWhere: startWhere
        )
        session = started
        save()
        startActivity(startedAt: started.startedAt)
        sessionChanged()
    }

    /// Ends the session. Rejects an end position before the start position.
    func end(endPositionMs: Int?, endWhere: String?) -> Bool {
        do {
            try LiveSessionPositionMap.validate(startPositionMs: session?.startPositionMs, endPositionMs: endPositionMs)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        mergeMarks()
        session?.endedAt = Date()
        session?.endPositionMs = endPositionMs
        session?.endWhere = endWhere
        save()
        endActivities()
        sessionChanged()
        return true
    }

    /// Adds a Margin now. `adjustmentMs` is the listener's slide of the predicted position; nonzero stores it as
    /// their own position.
    func addMargin(text: String, whereNote: String?, adjustmentMs: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, let current = session, !trimmed.isEmpty else { return }
        let markedAt = Date()
        var margin = current.margin(id: UUID().uuidString.lowercased(), text: trimmed, markedAt: markedAt, whereNote: whereNote)
        if adjustmentMs != 0, let estimate = LiveSessionPositionMap.position(at: markedAt, in: current) {
            margin.listenerPositionMs = max(0, estimate.ms + adjustmentMs)
        }
        session?.margins.append(margin)
        session?.margins.sort { $0.markedAt < $1.markedAt }
        save()
    }

    func updateText(id: String, text: String) {
        guard let index = session?.margins.firstIndex(where: { $0.id == id }) else { return }
        session?.margins[index].text = text
        save()
    }

    func removeMargin(id: String) {
        session?.margins.removeAll { $0.id == id }
        save()
    }

    /// Forgets the session and its Margins.
    func discard() {
        if isRecordingSpoken {
            isRecordingSpoken = false
            Task { [phoneRecorder, spokenStart] in
                await spokenStart?.value
                await phoneRecorder.cancel()
            }
        }
        endActivities()
        session = nil
        saveGeneration += 1
        let generation = saveGeneration
        Task { [files] in await files.remove(generation: generation) }
        sessionChanged()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let diskObserver { NotificationCenter.default.removeObserver(diskObserver) }
        diskObserver = nil
    }

    // MARK: Spoken Margins (#2487)

    /// Starts a spoken Margin on the phone. During a call it says to use the Watch instead: the call holds the
    /// phone's microphone, so nothing would be recorded.
    func startSpokenMargin() {
        guard isRunning, !isRecordingSpoken else { return }
        isRecordingSpoken = true
        spokenStart = Task { [weak self, phoneRecorder] in
            do {
                try await LiveSessionPhoneRecorder.checkCanRecord()
                try await phoneRecorder.start()
            } catch {
                self?.isRecordingSpoken = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Stops the spoken Margin, files it at the moment it was started, and transcribes it on the device.
    func stopSpokenMargin() {
        guard isRecordingSpoken else { return }
        isRecordingSpoken = false
        Task { [weak self, phoneRecorder, spokenStart] in
            await spokenStart?.value // a stop tapped while the start was still opening the microphone waits for it
            do {
                guard let recording = try await phoneRecorder.stop() else { return }
                self?.fileSpokenMargin(recording)
            } catch {
                self?.errorMessage = "Couldn't save the spoken Margin: \(error.localizedDescription)"
            }
        }
    }

    private func fileSpokenMargin(_ recording: LiveSessionPhoneRecorder.Recording) {
        guard isRunning else { return }
        let id = "phone-\(UUID().uuidString.lowercased())"
        session?.attachSpokenMargin(
            id: id, audioPath: recording.audioPath, markedAt: recording.startedAt,
            durationMs: recording.durationMs, spokenOn: "phone"
        )
        save()
        Task { [weak self] in
            guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: recording.audioPath) else { return }
            if self?.session?.setTranscript(text, forMarginId: id) == true { self?.save() }
        }
    }

    /// The stored session changed underneath (a Watch Margin arrived, or a transcript finished): take in Margins
    /// and transcripts this screen doesn't have yet. What the listener changed here wins.
    private func reconcileWithDisk() {
        Task { [weak self, files] in
            guard let stored = await files.load() else { return }
            self?.takeIn(stored)
        }
    }

    private func takeIn(_ stored: LiveSession) {
        guard stored.id == session?.id else { return }
        var changed = false
        for margin in stored.margins {
            if let index = session?.margins.firstIndex(where: { $0.id == margin.id }) {
                if let text = margin.spokenTranscript, session?.margins[index].spokenTranscript == nil {
                    changed = session?.setTranscript(text, forMarginId: margin.id) == true || changed
                }
            } else {
                session?.margins.append(margin)
                changed = true
            }
        }
        guard changed else { return }
        session?.margins.sort { $0.markedAt < $1.markedAt }
        save()
    }

    private func observeDisk() {
        guard diskObserver == nil else { return }
        diskObserver = NotificationCenter.default.addObserver(
            forName: LiveSessionSpokenMargins.changedOnDisk, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileWithDisk() }
        }
    }

    /// Tells the Watch about the session, and files any Watch Margins that waited for one.
    private func sessionChanged() {
        WatchMarginReceiver.shared.publish(session: isRunning ? session : nil)
        WatchMarginReceiver.shared.processInbox()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                self?.mergeMarks()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func mergeMarks() {
        guard isRunning else { return }
        let marks = LiveSessionMarkQueue.drain()
        guard !marks.isEmpty else { return }
        if session?.mergeMarks(marks) ?? 0 > 0 { save() }
    }

    /// Hands the session to the file worker. Saves land in the order they were made; an older one never
    /// overwrites a newer one.
    private func save() {
        guard let session else { return }
        saveGeneration += 1
        let generation = saveGeneration
        Task { [weak self, files] in
            do {
                try await files.save(session, generation: generation)
            } catch {
                self?.errorMessage = "Couldn't save the live session: \(error.localizedDescription)"
            }
        }
    }

    private func startActivity(startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The Lock Screen Mark is a convenience; the session works without it.
        _ = try? Activity<LiveSessionActivityAttributes>.request(
            attributes: LiveSessionActivityAttributes(sessionStartedAt: startedAt),
            content: ActivityContent(state: .init(markCount: 0), staleDate: nil),
            pushType: nil
        )
    }

    private func endActivities() {
        Task {
            for activity in Activity<LiveSessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
