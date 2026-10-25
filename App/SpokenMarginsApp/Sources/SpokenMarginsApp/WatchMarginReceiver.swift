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
        publish(session: await files.runningSession())
        if changed { announceChange() }
        for margin in pass.filed {
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

    /// The session state the Watch is sent: id, kind, title, start and start position, or empty for none.
    static func context(for session: LiveSession?) -> [String: Any] {
        guard let session else { return [:] }
        var context: [String: Any] = [
            WatchLiveSessionContext.startedAt: session.startedAt.timeIntervalSince1970,
            WatchLiveSessionContext.title: session.title,
            WatchLiveSessionContext.id: session.id,
            WatchLiveSessionContext.kind: session.kind.rawValue
        ]
        if let start = session.startPositionMs { context[WatchLiveSessionContext.startPositionMs] = start }
        return context
    }

    /// Sends the running session's state to the Watch, or clears it.
    func publish(session: LiveSession?) {
        let context = Self.context(for: session)
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
            guard let data = try? JSONEncoder().encode(answer) else { continue }
            WCSession.default.transferUserInfo([WatchMarginAnswer.userInfoKey: data])
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
}
#endif
