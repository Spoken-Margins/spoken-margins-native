import Foundation
import SessionKit

#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

/// Takes in spoken Margins recorded on the Apple Watch (#2487). During a phone call the call holds the iPhone's
/// microphone even when muted, but the Watch's microphone still records, so the Watch app records the Margin and
/// sends the file with `transferFile`.
///
/// iOS deletes a received file when the delegate call returns, so each one is moved at once into an inbox in the
/// app's own container, with its metadata beside it. The inbox is then filed into the live session (the one whose
/// span holds the recording's start, else the most recent; `LiveSessionWatchMatch`) as a spoken Margin, and
/// transcribed on the device. A Margin that arrives with no session waits in the inbox for the next one. A repeated
/// transfer is ignored by its id.
///
/// It also tells the Watch about the running session (`updateApplicationContext`), so the Watch can show
/// "about 12:40" while it records.
@MainActor
final class WatchMarginReceiver: NSObject {
    static let shared = WatchMarginReceiver()

    /// Called at launch, so a transfer that woke the app in the background is delivered.
    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
        processInbox()
    }

    /// Files each waiting Watch Margin into the stored live session. The inbox's files are read and moved on
    /// `LiveSessionFileWorker`, off the main thread; one pass runs at a time there, so each Margin is filed once.
    func processInbox() {
        Task {
            let filed = await LiveSessionFileWorker.shared.fileWatchInbox()
            guard !filed.isEmpty else { return }
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            for margin in filed {
                guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: margin.audioPath) else { continue }
                let id = margin.marginId
                await LiveSessionSpokenMargins.updateStored { $0.setTranscript(text, forMarginId: id) }
            }
        }
    }

    /// Sends the running session's start and start position to the Watch, or clears it.
    func publish(session: LiveSession?) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        var context: [String: Any] = [:]
        if let session {
            context[WatchLiveSessionContext.startedAt] = session.startedAt.timeIntervalSince1970
            if let start = session.startPositionMs { context[WatchLiveSessionContext.startPositionMs] = start }
            context[WatchLiveSessionContext.title] = session.title
        }
        try? WCSession.default.updateApplicationContext(context)
        #endif
    }
}

/// The application-context keys the phone sends the Watch. The Watch app's `WatchLiveSessionContext` must match.
enum WatchLiveSessionContext {
    static let startedAt = "liveSessionStartedAt"
    static let startPositionMs = "liveSessionStartPositionMs"
    static let title = "liveSessionTitle"
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
        guard let transfer = WatchMarginTransfer(metadata: file.metadata) else { return }
        do {
            try LiveSessionFileWorker.shared.storeIncoming(fileAt: file.fileURL, transfer: transfer)
        } catch {
            return
        }
        Task { @MainActor in self.processInbox() }
    }
}
#endif
