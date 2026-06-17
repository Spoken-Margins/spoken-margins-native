import Foundation
import SessionKit
@preconcurrency import WatchConnectivity

@MainActor
final class WatchTetheredModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var snapshot: CompactControlSnapshot?
    @Published var status = "Connecting"
    @Published var lastError: String?
    @Published private var optimisticRecording = false

    private struct IncomingPayload: Sendable {
        var type: String?
        var snapshotData: Data?
        var errorMessage: String?
    }

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
        optimisticRecording || snapshot?.isRecording == true
    }

    var isPlaying: Bool {
        snapshot?.status == .playing
    }

    var canSendCommands: Bool {
        snapshot?.compactSurfaceReady == true
    }

    var timeline: [CompactTimelineEntry] {
        snapshot?.timeline ?? []
    }

    var hasTimeline: Bool {
        !timeline.isEmpty
    }

    func canSend(_ command: CompactControlCommand) -> Bool {
        if optimisticRecording {
            switch command {
            case .finishInterjection, .cancelInterjection:
                return canSendCommands
            case .beginInterjection:
                return false
            default:
                break
            }
        }
        guard canSendCommands else { return false }
        return snapshot?.availableCommands.contains(command) == true
    }

    func refresh() {
        send(message: ["type": "requestSnapshot"])
    }

    func send(_ command: CompactControlCommand) {
        send(command, extra: [:])
    }

    func skipBack() {
        send(.skipBack, extra: [:])
    }

    func skipForward() {
        send(.skipForward, extra: [:])
    }

    func jumpToChapter(_ chapterId: String) {
        send(.jumpToChapter, extra: ["chapterId": chapterId])
    }

    func discuss() {
        send(.submitFollowup, extra: ["followUpText": "Can you respond to my interjection?"])
    }

    private func send(_ command: CompactControlCommand, extra: [String: Any]) {
        applyOptimisticState(for: command)
        var message = extra
        message["type"] = "command"
        message["command"] = command.rawValue
        send(message: message)
    }

    private func applyOptimisticState(for command: CompactControlCommand) {
        switch command {
        case .beginInterjection:
            optimisticRecording = true
        case .finishInterjection, .cancelInterjection:
            optimisticRecording = false
        default:
            break
        }
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
            if message["type"] as? String == "command" {
                session.transferUserInfo(message)
                status = "Queued for iPhone"
                return
            }
            status = "Open Spoken Margins on iPhone"
            return
        }
        status = "Sending"
        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                self?.lastError = message
                self?.status = "Send failed"
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let status = error.map { "Activation failed: \($0.localizedDescription)" } ?? "Connected"
        let payload = Self.payload(from: session.receivedApplicationContext)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = status
            self.handle(payload)
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = reachable ? "Connected" : "Open iPhone app"
            if reachable {
                self.refresh()
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = Self.payload(from: applicationContext)
        Task { @MainActor [weak self] in
            self?.handle(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let payload = Self.payload(from: message)
        Task { @MainActor [weak self] in
            self?.handle(payload)
        }
    }

    nonisolated private static func payload(from message: [String: Any]) -> IncomingPayload {
        IncomingPayload(
            type: message["type"] as? String,
            snapshotData: message["snapshot"] as? Data,
            errorMessage: message["error"] as? String
        )
    }

    private func handle(_ payload: IncomingPayload) {
        guard let type = payload.type else { return }
        if type == "snapshot", let data = payload.snapshotData {
            do {
                snapshot = try JSONDecoder().decode(CompactControlSnapshot.self, from: data)
                optimisticRecording = snapshot?.isRecording == true
                status = "Ready"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                status = "Decode failed"
            }
        } else if type == "error" {
            lastError = payload.errorMessage
            status = "Phone error"
        }
    }
}
