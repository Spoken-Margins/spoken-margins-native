import ActivityKit
import Foundation
import SessionKit

/// Drives the live session screen (#1989, #2481): Margins on a clock while something plays or is read outside
/// the app, with nothing recorded. The session is kept in the session store (`LiveSessionCollection`) so closing the app never loses
/// it; Lock Screen Marks arrive through `LiveSessionMarkQueue` and are filed by `LiveSessionFiling` (#2487 slice 1a).
/// Every disk read and write goes through `LiveSessionFileWorker` off the main thread (#2256); the screen keeps
/// the session in memory and only publishes what comes back.
@MainActor
final class LiveSessionController: ObservableObject {
    @Published private(set) var session: LiveSession?
    @Published var errorMessage: String?
    @Published private(set) var isRecordingSpoken = false

    private let files: LiveSessionFileWorker
    /// The session this screen opened: nil opens the running one, or the setup card when none runs.
    private let requestedSessionId: String?
    /// Rises with each save or discard, so the worker writes them in the order the screens made them. Shared by every
    /// screen: a counter per screen restarted at zero when the screen reopened, and the worker dropped its saves as stale.
    private static var generationCounter = 0
    private var saveGeneration = 0
    /// The last save or discard handed to the worker, so what follows it reads the store after it.
    private var lastWrite: Task<Void, Never>?
    private var spokenStart: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let phoneRecorder = LiveSessionPhoneRecorder()
    private var diskObserver: NSObjectProtocol?

    init(sessionId: String? = nil, files: LiveSessionFileWorker = .shared) {
        requestedSessionId = sessionId
        self.files = files
    }

    func load() {
        let generation = saveGeneration
        Task { [weak self, files, requestedSessionId] in
            let stored: LiveSession? = if let requestedSessionId {
                await files.session(id: requestedSessionId)
            } else {
                await files.runningSession()
            }
            guard let self else { return }
            // A session started or discarded while the file was read is newer than the file.
            if saveGeneration == generation { session = stored }
            WatchMarginReceiver.shared.fileWaitingMarks()
            startPolling()
            observeDisk()
            sessionChanged()
            await LiveSessionSpokenMargins.transcribeMissing()
        }
    }

    var isRunning: Bool { session != nil && session?.endedAt == nil }
    var hasEnded: Bool { session?.endedAt != nil }

    /// The clock is not published: the screen draws it from a `TimelineView`, so a tick redraws the clock and nothing
    /// else (a tick that redrew the whole screen closed its menus and sheets, #2831).
    func elapsedMs(at now: Date) -> Int {
        guard let session else { return 0 }
        let end = session.endedAt ?? now
        return max(0, Int((end.timeIntervalSince(session.startedAt) * 1_000).rounded()))
    }

    /// The estimated source position now, "about 1:23:10", when the listener gave a start position.
    func predictedPosition(at now: Date, adjustmentMs: Int = 0) -> LiveSessionPositionMap.Position? {
        guard let session, var position = LiveSessionPositionMap.position(at: now, in: session) else { return nil }
        position.ms = max(0, position.ms + adjustmentMs)
        return position
    }

    func start(kind: ElsewhereKind, title: String, startPositionMs: Int?, startWhere: String?) {
        // Marks from before this session are filed by their time, so they don't land in it (slice 1a point 7).
        WatchMarginReceiver.shared.fileWaitingMarks()
        let started = LiveSession(
            id: "live-\(UUID().uuidString.lowercased())", kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: Date(),
            startPositionMs: startPositionMs, startWhere: startWhere
        )
        session = started
        save()
        startActivity(for: started)
        sessionChanged()
    }

    /// Ends the session, which stopped at `when` (#2709). Rejects an end position before the start position, and a
    /// stopped time before the session began or in the future.
    func end(when: LiveSessionEnd.When = .now, endPositionMs: Int?, endWhere: String?) -> Bool {
        guard var ending = session else { return false }
        do {
            try LiveSessionEnd.end(&ending, when: when, tappedAt: Date(), endPositionMs: endPositionMs, endWhere: endWhere)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        WatchMarginReceiver.shared.fileWaitingMarks()
        session = ending
        save()
        endActivities()
        sessionChanged()
        return true
    }

    // MARK: Editing while it runs (#2832)

    func setKind(_ kind: ElsewhereKind) { edit { LiveSessionEdit.setKind(kind, on: &$0) } }

    func setTitle(_ title: String) { edit { LiveSessionEdit.setTitle(title, on: &$0) } }

    func setStartWhere(_ text: String) { edit { LiveSessionEdit.setStartWhere(text, on: &$0) } }

    /// "The source is at `positionMs` now." Returns false, with `errorMessage` set, when that can't be.
    @discardableResult
    func setSourceClock(positionMs: Int) -> Bool {
        guard isRunning, var edited = session else { return false }
        do {
            try LiveSessionEdit.setSourceClock(positionMs: positionMs, at: Date(), on: &edited)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        session = edited
        save()
        refreshActivities()
        sessionChanged()
        return true
    }

    private func edit(_ change: (inout LiveSession) -> Void) {
        guard isRunning, var edited = session else { return }
        change(&edited)
        guard edited != session else { return }
        session = edited
        save()
        refreshActivities()
        sessionChanged()
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
        Task { [files] in await files.forgetMargin(id: id) } // a late copy from the Watch never brings it back
        save()
    }

    /// Lets go of a session that was saved as a Library item (`Gate1AppModel.saveLiveSession` marks it saved).
    func close() {
        endActivities()
        session = nil
        sessionChanged()
    }

    /// Deletes the session and its Margins, and records that, so a late copy of one of them is refused.
    func discard() {
        if isRecordingSpoken {
            isRecordingSpoken = false
            Task { [phoneRecorder, spokenStart] in
                await spokenStart?.value
                await phoneRecorder.cancel()
            }
        }
        endActivities()
        let discarded = session?.id
        session = nil
        let generation = nextGeneration()
        if let discarded {
            lastWrite = Task { [files] in await files.discard(sessionId: discarded, generation: generation) }
        }
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
        guard let id = session?.id else { return }
        Task { [weak self, files] in
            guard let stored = await files.session(id: id) else { return }
            self?.takeIn(stored)
        }
    }

    private func takeIn(_ stored: LiveSession) {
        guard stored.id == session?.id else { return }
        var changed = takeInLifecycle(stored)
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

    /// An End, Resume or later start that came from the Watch (slice 1b) is the store's to say: take it in. The
    /// screen's own End is never undone, because the Watch's changes are the only ones that set these fields.
    private func takeInLifecycle(_ stored: LiveSession) -> Bool {
        guard let current = session else { return false }
        let endedByWatch = current.endedAt == nil && stored.endedAt != nil && stored.endReason != nil
        let resumedByWatch = current.endedAt != nil && stored.endedAt == nil
            && (stored.resumedAt.map { $0 > (current.endedAt ?? .distantFuture) } ?? false)
        guard endedByWatch || resumedByWatch else { return false }
        session?.endedAt = stored.endedAt
        session?.endTappedAt = stored.endTappedAt
        session?.endReason = stored.endReason
        session?.endNote = stored.endNote
        session?.resumedAt = stored.resumedAt
        session?.startedAt = stored.startedAt
        if endedByWatch { endActivities() }
        return true
    }

    private func observeDisk() {
        guard diskObserver == nil else { return }
        diskObserver = NotificationCenter.default.addObserver(
            forName: LiveSessionSpokenMargins.changedOnDisk, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileWithDisk() }
        }
    }

    /// Files anything waiting, tells the Watch the phone's view of the session (the pass sends the board), and
    /// refreshes the Library's Live row.
    private func sessionChanged() {
        let written = lastWrite
        Task {
            await written?.value // the pass reads the store after this screen's write, so it never re-sends a stale state
            await WatchMarginReceiver.shared.processInbox().value
            LiveSessionBoard.shared.refresh()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isRunning == true { WatchMarginReceiver.shared.fileWaitingMarks() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Hands the session to the file worker. Saves land in the order they were made; an older one never
    /// overwrites a newer one.
    private func save() {
        guard let session else { return }
        let generation = nextGeneration()
        lastWrite = Task { [weak self, files] in
            do {
                try await files.save(session, generation: generation)
            } catch {
                self?.errorMessage = "Couldn't save the live session: \(error.localizedDescription)"
            }
        }
    }

    private func nextGeneration() -> Int {
        Self.generationCounter += 1
        saveGeneration = Self.generationCounter
        return saveGeneration
    }

    private func startActivity(for session: LiveSession) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // The Lock Screen Mark is a convenience; the session works without it.
        _ = try? Activity<LiveSessionActivityAttributes>.request(
            attributes: LiveSessionActivityAttributes(sessionStartedAt: session.startedAt),
            content: ActivityContent(state: Self.activityState(for: session, markCount: 0, lastMarkAt: nil), staleDate: nil),
            pushType: nil
        )
    }

    private static func activityState(for session: LiveSession, markCount: Int, lastMarkAt: Date?) -> LiveSessionActivityAttributes.ContentState {
        .init(
            markCount: markCount, lastMarkAt: lastMarkAt,
            clockOrigin: LiveSessionClock.origin(of: session), clockTitle: LiveSessionClock.title(for: session.kind)
        )
    }

    /// The Lock Screen shows the source's clock (#2834), so a change to the kind or the clock reaches it.
    private func refreshActivities() {
        guard let session else { return }
        Task {
            for activity in Activity<LiveSessionActivityAttributes>.activities {
                let current = activity.content.state
                let state = Self.activityState(for: session, markCount: current.markCount, lastMarkAt: current.lastMarkAt)
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    private func endActivities() {
        Task {
            for activity in Activity<LiveSessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
