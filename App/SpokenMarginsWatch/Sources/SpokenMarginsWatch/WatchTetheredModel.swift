import Foundation
import SessionKit
import WatchConnectivity

final class WatchTetheredModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var snapshot: CompactControlSnapshot?
    @Published var status = "Connecting"
    @Published var lastError: String?

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    var isReachable: Bool {
        session?.isReachable == true
    }

    var chapterTitle: String {
        snapshot?.chapterTitle ?? snapshot?.title ?? "Open the phone app"
    }

    var targetLabel: String {
        switch snapshot?.targetType {
        case TargetType.summaryTurnTTS.rawValue:
            return "Current Summary"
        case TargetType.assistantTurnTTS.rawValue:
            return "Current Discussion"
        default:
            return "Current Chapter"
        }
    }

    var progressText: String {
        guard let snapshot else { return "Waiting for iPhone" }
        return "\(snapshot.currentPlaybackProgressPercent)% current / \(snapshot.sourceProgressPercent)% source"
    }

    var isRecording: Bool {
        snapshot?.isRecording == true
    }

    var isPlaying: Bool {
        snapshot?.status == .playing
    }

    var canSendCommands: Bool {
        snapshot?.compactSurfaceReady == true
    }

    func canSend(_ command: CompactControlCommand) -> Bool {
        guard canSendCommands else { return false }
        return snapshot?.availableCommands.contains(command) == true
    }

    func refresh() {
        send(message: ["type": "requestSnapshot"])
    }

    func send(_ command: CompactControlCommand) {
        send(command, extra: [:])
    }

    func skipBackChapter() {
        send(.skipBack, extra: ["unit": "chapter"])
    }

    func skipForwardChapter() {
        send(.skipForward, extra: ["unit": "chapter"])
    }

    func jumpToChapter(_ chapterId: String) {
        send(.jumpToChapter, extra: ["chapterId": chapterId])
    }

    func discuss() {
        send(.submitFollowup, extra: ["followUpText": "Can you respond to my interjection?"])
    }

    private func send(_ command: CompactControlCommand, extra: [String: Any]) {
        var message = extra
        message["type"] = "command"
        message["command"] = command.rawValue
        send(message: message)
    }

    private func send(message: [String: Any]) {
        guard let session else {
            status = "WatchConnectivity unavailable"
            return
        }
        guard session.activationState == .activated else {
            status = "Pairing"
            session.activate()
            return
        }
        guard session.isReachable else {
            status = "Open Spoken Margins on iPhone"
            return
        }
        status = "Sending"
        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            DispatchQueue.main.async {
                self?.lastError = error.localizedDescription
                self?.status = "Send failed"
            }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.status = error.map { "Activation failed: \($0.localizedDescription)" } ?? "Connected"
            self.handle(message: session.receivedApplicationContext)
            self.refresh()
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.status = session.isReachable ? "Connected" : "Open iPhone app"
            if session.isReachable {
                self.refresh()
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.handle(message: applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.handle(message: message)
        }
    }

    private func handle(message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if type == "snapshot", let data = message["snapshot"] as? Data {
            do {
                snapshot = try JSONDecoder().decode(CompactControlSnapshot.self, from: data)
                status = "Ready"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                status = "Decode failed"
            }
        } else if type == "error" {
            lastError = message["error"] as? String
            status = "Phone error"
        }
    }
}
