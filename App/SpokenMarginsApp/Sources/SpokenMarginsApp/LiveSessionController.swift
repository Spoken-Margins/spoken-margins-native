import Combine
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
    /// The phone is recording a spoken Margin for this session. The recording itself belongs to
    /// `LiveSessionSpokenCapture`, not to this screen, so closing or losing the screen never loses it (#3489).
    var isRecordingSpoken: Bool { spokenCapture.isRecording(for: session?.id) }
    /// True once the stored session has been read, so a link waiting on it knows whether there is one to act on.
    @Published private(set) var didLoad = false

    private let files: LiveSessionFileWorker
    /// The session this screen opened: nil opens the running one, or the setup card when none runs.
    private let requestedSessionId: String?
    /// Rises with each save or discard, so the worker writes them in the order the screens made them. Shared by every
    /// screen: a counter per screen restarted at zero when the screen reopened, and the worker dropped its saves as stale.
    private static var generationCounter = 0
    private var saveGeneration = 0
    /// The last save or discard handed to the worker, so what follows it reads the store after it.
    private var lastWrite: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var clockStartTask: Task<Void, Never>?
    /// Removes the "Ended · Resume" card when its window closes (#2883), if the app is still running then.
    private var endedCardExpiry: Task<Void, Never>?
    private let spokenCapture: LiveSessionSpokenCapture
    private var captureObservers: Set<AnyCancellable> = []
    private var diskObserver: NSObjectProtocol?
    /// Finish tapped on the Lock Screen card while a spoken Margin records (#3499); lives only while one records.

    init(sessionId: String? = nil, files: LiveSessionFileWorker = .shared, spokenCapture: LiveSessionSpokenCapture = .shared) {
        requestedSessionId = sessionId
        self.files = files
        self.spokenCapture = spokenCapture
        spokenCapture.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &captureObservers)
        spokenCapture.$notice
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                self?.errorMessage = notice
                self?.spokenCapture.notice = nil
            }
            .store(in: &captureObservers)
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
            didLoad = true
            // A card left on "Recording" by an earlier screen or run goes back to Mark (#3499).
            if let id = session?.id { spokenCapture.syncCard(for: id) }
            WatchMarginReceiver.shared.fileWaitingMarks()
            startPolling()
            observeDisk()
            sessionChanged()
            await LiveSessionActivities.endExpired()
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

    func start(kind: ElsewhereKind, title: String, startPositionMs: Int?, startWhere: String?, startPlace: LiveSessionPlace? = nil) {
        // Marks from before this session are filed by their time, so they don't land in it (slice 1a point 7).
        WatchMarginReceiver.shared.fileWaitingMarks()
        var started = LiveSession(
            id: "live-\(UUID().uuidString.lowercased())", kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: Date(),
            startPositionMs: startPositionMs, startWhere: startWhere
        )
        started.startPlace = startPlace
        session = started
        save()
        LiveSessionActivities.start(for: started)
        sessionChanged()
    }

    /// Ends the session, which stopped at `when` (#2709). Rejects an end position before the start position, and a
    /// stopped time before the session began or in the future.
    func end(when: LiveSessionEnd.When = .now, endPositionMs: Int?, endWhere: String?, endPlace: LiveSessionPlace? = nil) -> Bool {
        guard var ending = session else { return false }
        do {
            try LiveSessionEnd.end(&ending, when: when, tappedAt: Date(), endPositionMs: endPositionMs, endWhere: endWhere, endPlace: endPlace)
        } catch {
            errorMessage = ListenerErrorText.message(for: error)
            return false
        }
        // A spoken Margin still recording is stopped and saved, never dropped (#3489). It files into the store at its
        // start, which is inside the session; this screen takes it in when it lands.
        if isRecordingSpoken { stopSpokenMargin() }
        WatchMarginReceiver.shared.fileWaitingMarks()
        session = ending
        save()
        showEndedActivity(for: ending)
        sessionChanged()
        return true
    }

    /// Reopens the session just ended, within the Resume window (#2883), by the same rules as the Watch's Resume. The
    /// Lock Screen card, the Library's Live row and the Watch follow.
    func resume() {
        guard hasEnded, let id = session?.id else { return }
        let written = lastWrite
        Task { [weak self] in
            await written?.value // the store has this screen's End before the Resume reads it
            guard let resumed = await LiveSessionResumer.resume(id: id) else {
                self?.errorMessage = LiveSessionResumer.refusedWords
                return
            }
            self?.takeIn(resumed)
        }
    }

    /// When Resume stops being offered for the ended session on screen, so the button can go at that moment. Nil when
    /// it isn't offered. The window runs from the tap on End.
    var resumeUntil: Date? {
        guard let session else { return nil }
        return LiveSessionWatchSessions.resumableUntil(id: session.id, sessions: [session.id: session])
    }

    // MARK: Editing while it runs (#2832)

    func setKind(_ kind: ElsewhereKind) { edit { LiveSessionEdit.setKind(kind, on: &$0) } }

    func setTitle(_ title: String) { edit { LiveSessionEdit.setTitle(title, on: &$0) } }

    func setStartWhere(_ text: String) { edit { LiveSessionEdit.setStartWhere(text, on: &$0) } }

    /// What the session is about (#3491). Allowed while it runs and after it ends, until it is saved.
    func setDescription(_ text: String) { editUnsaved { LiveSessionEdit.setDescription(text, on: &$0) } }

    /// The start time the listener says it had (#3491), display and export only. Returns false, with
    /// `errorMessage` set, for a time in the future or after the end. Allowed until the session is saved.
    @discardableResult
    func setStatedStart(_ date: Date?) -> Bool {
        guard canEditUnsaved, var edited = session else { return false }
        do {
            try LiveSessionEdit.setStatedStart(date, now: Date(), on: &edited)
        } catch {
            errorMessage = ListenerErrorText.message(for: error)
            return false
        }
        commitUnsaved(edited)
        return true
    }

    private var canEditUnsaved: Bool { session != nil && session?.savedItemId == nil }

    private func editUnsaved(_ change: (inout LiveSession) -> Void) {
        guard canEditUnsaved, var edited = session else { return }
        change(&edited)
        commitUnsaved(edited)
    }

    private func commitUnsaved(_ edited: LiveSession) {
        guard edited != session else { return }
        session = edited
        save()
        refreshActivities()
        sessionChanged()
    }

    /// "The source is at `positionMs` now." Returns false, with `errorMessage` set, when that can't be.
    @discardableResult
    func setSourceClock(positionMs: Int) -> Bool {
        guard isRunning, var edited = session else { return false }
        do {
            try LiveSessionEdit.setSourceClock(positionMs: positionMs, at: Date(), on: &edited)
        } catch {
            errorMessage = ListenerErrorText.message(for: error)
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
    func addMargin(text: String, whereNote: String?, adjustmentMs: Int, markedAt: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, let current = session, !trimmed.isEmpty else { return }
        let margin = writtenMargin(trimmed, whereNote: whereNote, adjustmentMs: adjustmentMs, markedAt: markedAt, in: current)
        session?.margins.append(margin)
        session?.margins.sort { $0.markedAt < $1.markedAt }
        save()
    }

    /// Adds a written Margin that was taken with a photo (#2708). The photo's file is moved into place first and the Margin
    /// that names it is saved after, so a crash never leaves a Margin naming a file that was never kept. When the file
    /// can't be kept the Margin is saved without it and the listener is told: they never lose their words to the picture.
    func addMargin(
        text: String, whereNote: String?, adjustmentMs: Int, markedAt: Date, photo staged: LiveSessionPhotoStore.Staged
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, let current = session, !trimmed.isEmpty else {
            await files.discardStaged(staged)
            return
        }
        var margin = writtenMargin(trimmed, whereNote: whereNote, adjustmentMs: adjustmentMs, markedAt: markedAt, in: current)
        if let photo = await files.commitPhoto(staged, sessionId: current.id, marginId: margin.id) {
            margin.photo = photo
        } else {
            errorMessage = LiveSessionPhotoMargin.couldNotKeepLine
        }
        // The session may have ended its screen, or been discarded, while the file moved.
        guard session?.id == current.id else {
            if let photo = margin.photo { await files.removePhoto(photo) }
            return
        }
        session?.margins.append(margin)
        session?.margins.sort { $0.markedAt < $1.markedAt }
        save()
    }

    private func writtenMargin(
        _ trimmed: String, whereNote: String?, adjustmentMs: Int, markedAt: Date, in current: LiveSession
    ) -> LiveSessionMargin {
        var margin = current.margin(id: UUID().uuidString.lowercased(), text: trimmed, markedAt: markedAt, whereNote: whereNote)
        // "page 118" typed with the Margin is the listener's own place, in their unit (#2707).
        if let whereNote {
            margin.place = LiveSessionPlace.parseWhole(whereNote, defaultUnit: LiveSessionPlace.defaultUnit(for: current.kind), allowsTime: false)
        }
        if adjustmentMs != 0, let estimate = LiveSessionPositionMap.position(at: markedAt, in: current) {
            margin.listenerPositionMs = max(0, estimate.ms + adjustmentMs)
        }
        return margin
    }

    /// Throws away a photo that never became part of a Margin (Cancel on the recording or the writing screen).
    func discardPhoto(_ staged: LiveSessionPhotoStore.Staged) {
        Task { [files] in await files.discardStaged(staged) }
    }

    /// Keeps the page, percent or chapter heard in a Margin's words as that Margin's checkpoint (#2707).
    func keepHeardPlace(id: String) {
        guard session?.keepHeardPlace(forMarginId: id) == true else { return }
        save()
    }

    func declineHeardPlace(id: String) {
        guard session?.declineHeardPlace(forMarginId: id) == true else { return }
        save()
    }

    /// Takes the meeting start that the end clock implies, when it disagrees with the one typed (#2707).
    func useImpliedStart() {
        guard hasEnded, var edited = session, LiveSessionEdit.useImpliedStart(on: &edited) else { return }
        session = edited
        save()
        sessionChanged()
    }

    func updateText(id: String, text: String) {
        guard let index = session?.margins.firstIndex(where: { $0.id == id }) else { return }
        session?.margins[index].text = text
        save()
    }

    func removeMargin(id: String) {
        let photo = session?.margins.first { $0.id == id }?.photo
        session?.margins.removeAll { $0.id == id }
        Task { [files] in await files.forgetMargin(id: id) } // a late copy from the Watch never brings it back
        if let photo {
            // Deleting a Margin deletes its photo file (#2708).
            LiveSessionPhotoImages.forget(photo)
            Task { [files] in await files.removePhoto(photo) }
        }
        save()
    }

    /// Lets go of a session that was saved as a Library item (`Gate1AppModel.saveLiveSession` marks it saved).
    func close() {
        if isRecordingSpoken { stopSpokenMargin() }
        endActivities()
        session = nil
        sessionChanged()
    }

    /// Deletes the session and its Margins, and records that, so a late copy of one of them is refused.
    func discard() {
        if let id = session?.id { spokenCapture.cancel(sessionId: id) }
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
        clockStartTask?.cancel()
        if let diskObserver { NotificationCenter.default.removeObserver(diskObserver) }
        diskObserver = nil
    }

    // MARK: Spoken Margins (#2487)

    /// Starts a spoken Margin on the phone. During a call it says to use the Watch instead: the call holds the
    /// phone's microphone, so nothing would be recorded.
    func startSpokenMargin(photo staged: LiveSessionPhotoStore.Staged? = nil, placedAt: Date? = nil) {
        guard isRunning, let id = session?.id, !isRecordingSpoken else {
            if let staged { discardPhoto(staged) } // a photo with no recording to join is not kept (#2708)
            return
        }
        spokenCapture.start(sessionId: id, photo: staged, placedAt: placedAt)
    }

    /// Stops the spoken Margin and files it at the moment it was started; it is transcribed on the device. The
    /// filing goes through the store, and this screen takes the Margin in from there (`reconcileWithDisk`).
    func stopSpokenMargin() {
        guard isRecordingSpoken else { return }
        spokenCapture.stopAndFile()
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
        if var updated = session {
            for index in updated.margins.indices {
                let stored = stored.margins.first { $0.id == updated.margins[index].id }?.filingNote
                if endedByWatch {
                    // Margins taken between the stopped time and the tap were noted "after the session ended" by the store (#2709).
                    if updated.margins[index].filingNote == nil { updated.margins[index].filingNote = stored }
                } else if updated.margins[index].filingNote == LiveSessionFiling.afterEndNote, stored == nil {
                    updated.margins[index].filingNote = nil // resumed, so the gap's Margins are inside the session again
                }
            }
            session = updated
        }
        if endedByWatch, let ended = session { showEndedActivity(for: ended) }
        if resumedByWatch, let resumed = session {
            endedCardExpiry?.cancel()
            endedCardExpiry = nil
            Task { await LiveSessionActivities.showRunning(resumed) } // the card turns back into the running one
        }
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
                self?.errorMessage = ListenerErrorText.line(prefix: "Couldn't save the live session:", error: error)
            }
        }
    }

    private func nextGeneration() -> Int {
        Self.generationCounter += 1
        saveGeneration = Self.generationCounter
        return saveGeneration
    }

    /// The Lock Screen shows the source's clock (#2834), so a change to the kind or the clock reaches it.
    private func refreshActivities() {
        guard isRunning, let session else { return } // a timer that fires after End must not bring the running card back
        // A clock that has not begun yet (Start tapped in the lobby) shows on the Lock Screen when it does.
        clockStartTask?.cancel()
        if let begins = LiveSessionClock.beginsAt(session, now: Date()) {
            clockStartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, begins.timeIntervalSinceNow) + 0.5))
                guard !Task.isCancelled else { return }
                self?.refreshActivities()
            }
        }
        Task { await LiveSessionActivities.showRunning(session) }
    }

    /// The meeting is still going: leave it running and remind the listener once, if they have allowed notifications.
    func remindStillGoing() async {
        guard isRunning else { return }
        if await LiveSessionStillGoingReminder.schedule() {
            // Ended or discarded while the reminder was being set up: it must not arrive for a session that is over.
            if !isRunning { LiveSessionStillGoingReminder.cancel() }
            return
        }
        errorMessage = "Notifications aren't allowed for Spoken Margins, so it can't remind you. The session keeps running."
    }

    /// Removes the Lock Screen card now.
    private func endActivities() {
        LiveSessionStillGoingReminder.cancel()
        endedCardExpiry?.cancel()
        endedCardExpiry = nil
        Task { await LiveSessionActivities.endAll() }
    }

    /// After End the card stays as "Ended 14:05 · Resume" for the Resume window (#2883), then goes. With nothing to
    /// resume (a quick session, one already saved) it goes at once.
    private func showEndedActivity(for ended: LiveSession) {
        guard let plan = LiveSessionEndedActivity.plan(for: ended, now: Date()) else {
            endActivities()
            return
        }
        LiveSessionStillGoingReminder.cancel()
        clockStartTask?.cancel()
        endedCardExpiry?.cancel()
        Task { await LiveSessionActivities.showEnded(plan) }
        endedCardExpiry = Task {
            try? await Task.sleep(for: .seconds(max(0, plan.resumeUntil.timeIntervalSinceNow) + 1))
            guard !Task.isCancelled else { return }
            await LiveSessionActivities.endExpired()
        }
    }
}
