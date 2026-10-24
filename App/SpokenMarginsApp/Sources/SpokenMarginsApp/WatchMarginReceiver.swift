import Foundation
import SessionKit

#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

/// Takes in spoken Margins recorded on the Apple Watch and Marks from the Lock Screen, and files every one of them
/// somewhere the listener can see (#2487 slice 1a).
///
/// iOS deletes a received file when the delegate call returns, so each one is moved at once into a landing folder in
/// the app's own container, with its metadata beside it (`receive(fileAt:metadata:)`). A filing pass on
/// `LiveSessionFileWorker` then stores it in `WatchMarginInbox`, files it by `LiveSessionFiling` (the session whose
/// span holds it, a named session within 30 minutes of its end, else a quick session), and only then answers the Watch
/// with a `WatchMarginAnswer`. The Watch build before slice 1b ignores the answer. Nothing waits for a session any
/// more: the hidden inbox is gone, and what an earlier build left in it files on the first pass.
///
/// At launch (`activate`) it restores the running session from the store and tells the Watch about it
/// (`updateApplicationContext`), so the Watch shows "about 12:40" without the session screen being opened.
///
/// Slice 1b: the Watch's other messages (hello, start, end, resume, a Margin's details, withdraw) arrive on both lanes,
/// `sendMessage` with a reply and `transferUserInfo`. `handle(_:)` applies each on the worker, in order with the
/// filing passes, and the reply carries the phone's clock, the board and answers for what is already filed. Answers
/// always go on the sure lane as well.
@MainActor
final class WatchMarginReceiver: NSObject {
    static let shared = WatchMarginReceiver(files: .shared)

    let files: LiveSessionFileWorker
    /// The on-device transcription, replaceable in tests (which must not ask for speech recognition).
    var transcribe: @Sendable (String) async -> String? = { await LiveSessionSpokenMargins.transcribe(audioPath: $0) }
    /// Waiting Lock Screen Marks, removed as they are read.
    var drainMarks: () -> [Date] = { LiveSessionMarkQueue.drain() }
    /// What was last sent to the Watch as the session state, kept for the launch check and tests.
    private(set) var lastPublishedContext: [String: Any]?
    /// The last board sent, kept for tests.
    private(set) var lastBoard: WatchBoard?
    /// Answers handed to WatchConnectivity, newest last (at most 50), kept for tests and diagnostics.
    private(set) var sentAnswers: [WatchMarginAnswer] = []
    /// Passes run one after another, so each Margin is filed once.
    private var lastPass: Task<Void, Never>?

    init(files: LiveSessionFileWorker) {
        self.files = files
    }

    /// Called at launch, so a transfer that woke the app in the background is delivered and the running session is
    /// restored and sent to the Watch.
    func activate() {
        #if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        #endif
        processInbox()
    }

    /// Files waiting Watch Margins and Lock Screen Marks, answers the Watch, transcribes what was filed and sends the
    /// running session's state to the Watch. Returns the pass, which runs after any pass already under way.
    @discardableResult
    func processInbox() -> Task<Void, Never> {
        let previous = lastPass
        let pass = Task { [weak self] in
            await previous?.value
            await self?.runPass()
        }
        lastPass = pass
        return pass
    }

    /// Files Lock Screen Marks now, if any are waiting. Cheap when none are.
    func fileWaitingMarks() {
        let marks = drainMarks()
        guard !marks.isEmpty else { return }
        let previous = lastPass
        let files = files
        let pass = Task { [weak self] in
            await previous?.value
            let result = await files.fileMarks(marks)
            if result.changed { self?.announceChange() }
        }
        lastPass = pass
    }

    private func runPass() async {
        await transcribe(await fileWaiting())
    }

    /// Files what is waiting and answers the Watch, without transcribing.
    private func fileWaiting() async -> [LiveSessionFileWorker.FiledMargin] {
        let marks = drainMarks()
        var changed = false
        if !marks.isEmpty {
            changed = await files.fileMarks(marks).changed || changed
        }
        let pass = await files.fileWatchInbox()
        changed = pass.changed || changed
        for placement in pass.placements {
            // Slice 1a hands no player runs to the worker, so this is a safety net: file it by the rest of the rule.
            changed = await files.fileAsQuick(placement) || changed
        }
        send(pass.answers)
        publish(board: await files.watchBoard())
        if changed { announceChange() }
        return pass.filed
    }

    private func transcribe(_ filed: [LiveSessionFileWorker.FiledMargin]) async {
        for margin in filed {
            guard let text = await transcribe(margin.audioPath) else { continue }
            let id = margin.marginId
            await LiveSessionSpokenMargins.updateStored(in: files, marginId: id) { $0.setTranscript(text, forMarginId: id) }
        }
    }

    private func announceChange() {
        NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
    }

    /// What `session(_:didReceive:)` does with a received file: moves it into the landing folder before iOS deletes it.
    /// Returns false when it isn't a Watch Margin or couldn't be moved.
    nonisolated func receive(fileAt url: URL, metadata: [String: Any]?) -> Bool {
        guard let transfer = WatchMarginTransfer(metadata: metadata) else { return false }
        do {
            try files.storeIncoming(fileAt: url, transfer: transfer)
        } catch {
            return false
        }
        return true
    }

    /// Applies a message from the Watch, after any filing pass under way, and returns the reply. Waiting Margins are
    /// filed first, so one whose file has just landed is answered as filed; transcribing them waits until the reply
    /// is out, so the fast lane answers in a second, not after speech recognition.
    @discardableResult
    func handle(_ envelope: WatchEnvelope, now: @escaping @Sendable () -> Date = { Date() }) -> Task<WatchPhoneReply, Never> {
        let previous = lastPass
        let files = files
        let work = Task { [weak self] () -> (WatchPhoneReply, [LiveSessionFileWorker.FiledMargin]) in
            await previous?.value
            let filed = await self?.fileWaiting() ?? []
            let reply = await files.applyWatch(envelope, now: now())
            guard let self else { return (reply, filed) }
            self.send(reply.answers)
            self.publish(board: reply.board)
            switch envelope.message {
            case .sessionStart, .sessionEnd, .sessionResume, .withdraw:
                self.announceChange()
                LiveSessionBoard.shared.refresh()
            case .hello, .marginDetails:
                break
            }
            return (reply, filed)
        }
        lastPass = Task { [weak self] in
            let (_, filed) = await work.value
            await self?.transcribe(filed)
        }
        return Task { await work.value.0 }
    }

    /// The session state the Watch is sent: the board, plus the running session's start and title under the keys the
    /// Watch build before slice 1b reads.
    static func context(for board: WatchBoard) -> [String: Any] {
        var context: [String: Any] = [:]
        if let data = board.encoded { context[WatchContract.boardKey] = data }
        guard let session = board.running else { return context }
        context[WatchLiveSessionContext.startedAt] = session.startedAt.timeIntervalSince1970
        context[WatchLiveSessionContext.title] = session.title
        context[WatchLiveSessionContext.id] = session.id
        context[WatchLiveSessionContext.kind] = session.kind.rawValue
        if let start = session.startPositionMs { context[WatchLiveSessionContext.startPositionMs] = start }
        return context
    }

    /// Sends the phone's view of the session to the Watch.
    func publish(board: WatchBoard) {
        let context = Self.context(for: board)
        lastBoard = board
        lastPublishedContext = context
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        try? WCSession.default.updateApplicationContext(context)
        #endif
    }

    /// Answers each Margin on the sure lane, which queues while the Watch is away.
    private func send(_ answers: [WatchMarginAnswer]) {
        guard !answers.isEmpty else { return }
        sentAnswers = Array((sentAnswers + answers).suffix(50))
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        for answer in answers {
            let info = answer.userInfo
            if !info.isEmpty { WCSession.default.transferUserInfo(info) }
        }
        #endif
    }
}

/// The application-context keys the phone sends the Watch. The Watch app's `WatchLiveSessionContext` must match;
/// the Watch build before slice 1b reads only the first three.
enum WatchLiveSessionContext {
    static let startedAt = "liveSessionStartedAt"
    static let startPositionMs = "liveSessionStartPositionMs"
    static let title = "liveSessionTitle"
    static let id = "liveSessionId"
    static let kind = "liveSessionKind"
}

#if canImport(WatchConnectivity)
/// WatchConnectivity's reply block, carried across to the main actor.
private struct ReplyHandler: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

extension WatchMarginReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.processInbox() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate() // after switching watches
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard receive(fileAt: file.fileURL, metadata: file.metadata) else { return }
        Task { @MainActor in self.processInbox() }
    }

    /// The sure lane: answers go back on it too.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let envelope = WatchEnvelope(dictionary: userInfo) else { return }
        Task { @MainActor in self.handle(envelope) }
    }

    /// The fast lane: the reply carries the phone's clock, the board and any answers.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let envelope = WatchEnvelope(dictionary: message) else {
            replyHandler([:])
            return
        }
        let reply = ReplyHandler(send: replyHandler)
        Task { @MainActor in
            let answer = await self.handle(envelope).value
            reply.send(answer.dictionary)
        }
    }
}
#endif
