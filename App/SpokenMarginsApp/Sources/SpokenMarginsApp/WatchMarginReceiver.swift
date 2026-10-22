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

    /// Application Support, as `Gate1AppModel.liveSessionDirectory` names it, readable off the main actor.
    nonisolated static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    nonisolated static var inboxDirectory: URL? {
        applicationSupport?
            .appending(path: "LiveSession", directoryHint: .isDirectory)
            .appending(path: "WatchInbox", directoryHint: .isDirectory)
    }

    private var isProcessing = false

    /// Called at launch, so a transfer that woke the app in the background is delivered.
    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
        processInbox()
    }

    /// Files each waiting Watch Margin into the stored live session.
    func processInbox() {
        guard !isProcessing, let inbox = Self.inboxDirectory,
              let directory = Gate1AppModel.liveSessionDirectory,
              let session = LiveSessionStore.load(from: directory) else { return }
        isProcessing = true
        defer { isProcessing = false }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        var filed: [(marginId: String, audioPath: String)] = []
        for metadataURL in files where metadataURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  let transfer = try? JSONDecoder().decode(WatchMarginTransfer.self, from: data) else {
                try? FileManager.default.removeItem(at: metadataURL)
                continue
            }
            let audioURL = metadataURL.deletingPathExtension().appendingPathExtension("m4a")
            guard LiveSessionWatchMatch.sessionId(for: transfer.wallStart, among: [session.span]) == session.id,
                  let destination = Self.recordingURL(for: transfer.audioPath) else { continue }
            let alreadyFiled = session.margins.contains { $0.id == transfer.marginId }
            if !alreadyFiled {
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: audioURL, to: destination)
                } catch {
                    continue // the recording stays in the inbox for the next try
                }
                LiveSessionSpokenMargins.updateStored { $0.attach(transfer) }
                filed.append((transfer.marginId, transfer.audioPath))
            }
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }
        guard !filed.isEmpty else { return }
        Task {
            for margin in filed {
                guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: margin.audioPath) else { continue }
                LiveSessionSpokenMargins.updateStored { $0.setTranscript(text, forMarginId: margin.marginId) }
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

    /// The app's Application Support location of a recorder-style path ("SpokenMargins/interjections/…").
    nonisolated static func recordingURL(for audioPath: String) -> URL? {
        applicationSupport?.appending(path: audioPath)
    }

    /// Moves a received file into the inbox. Runs on the delegate's queue, before iOS deletes the file.
    nonisolated static func store(fileAt url: URL, transfer: WatchMarginTransfer) throws {
        guard let inbox = inboxDirectory else { return }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: transfer.audioPath).deletingPathExtension().lastPathComponent
        let audio = inbox.appending(path: "\(stem).m4a")
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        try FileManager.default.moveItem(at: url, to: audio)
        try JSONEncoder().encode(transfer).write(to: inbox.appending(path: "\(stem).json"), options: .atomic)
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
            try Self.store(fileAt: file.fileURL, transfer: transfer)
        } catch {
            return
        }
        Task { @MainActor in self.processInbox() }
    }
}
#endif
