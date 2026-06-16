import Foundation
import SessionKit

#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

struct Gate3WatchCommandRequest: Sendable {
    var command: CompactControlCommand
    var chapterId: String?
    var unit: String?
    var followUpText: String?
}

#if canImport(WatchConnectivity)
@MainActor
final class Gate3WatchConnectivityController: NSObject, WCSessionDelegate {
    private var snapshotProvider: (@MainActor () -> CompactControlSnapshot?)?
    private var commandHandler: (@MainActor (Gate3WatchCommandRequest) -> Void)?
    private var session: WCSession?
    private(set) var activationState = "inactive"
    private(set) var lastMessage = "none"

    func activate(
        snapshotProvider: @escaping @MainActor () -> CompactControlSnapshot?,
        commandHandler: @escaping @MainActor (Gate3WatchCommandRequest) -> Void
    ) {
        guard WCSession.isSupported() else {
            activationState = "unsupported"
            return
        }
        self.snapshotProvider = snapshotProvider
        self.commandHandler = commandHandler
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        activationState = "activating"
    }

    func publish(snapshot: CompactControlSnapshot?) {
        guard let snapshot, let payload = Self.payload(for: snapshot) else { return }
        #if os(iOS)
        guard session?.isWatchAppInstalled == true else {
            lastMessage = "watch_app_not_installed"
            return
        }
        #endif
        do {
            try session?.updateApplicationContext(payload)
            if session?.isReachable == true {
                session?.sendMessage(payload, replyHandler: nil)
            }
            lastMessage = "snapshot_sent"
        } catch {
            lastMessage = "snapshot_failed:\(error.localizedDescription)"
        }
    }

    func diagnostics() -> [String: String] {
        [
            "gate3WatchConnectivity": activationState,
            "gate3WatchInstalled": isWatchAppInstalled ? "true" : "false",
            "gate3WatchReachable": session?.isReachable == true ? "true" : "false",
            "gate3WatchLastMessage": lastMessage
        ]
    }

    private var isWatchAppInstalled: Bool {
        #if os(iOS)
        session?.isWatchAppInstalled == true
        #else
        true
        #endif
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activationState = error.map { "failed:\($0.localizedDescription)" } ?? "\(activationState.rawValue)"
            self.publish(snapshot: self.snapshotProvider?())
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activationState = "inactive"
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activationState = "deactivated"
            session.activate()
        }
    }
    #endif

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publish(snapshot: self.snapshotProvider?())
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String else {
            Task { @MainActor [weak self] in
                self?.lastMessage = "missing_type"
            }
            return
        }

        switch type {
        case "requestSnapshot":
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.publish(snapshot: self.snapshotProvider?())
            }
        case "command":
            guard let rawCommand = message["command"] as? String,
                  let command = CompactControlCommand(rawValue: rawCommand) else {
                Task { @MainActor [weak self] in
                    self?.lastMessage = "unsupported_command"
                }
                return
            }
            let request = Gate3WatchCommandRequest(
                command: command,
                chapterId: message["chapterId"] as? String,
                unit: message["unit"] as? String,
                followUpText: message["followUpText"] as? String
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.commandHandler?(request)
                self.publish(snapshot: self.snapshotProvider?())
            }
        default:
            Task { @MainActor [weak self] in
                self?.lastMessage = "unsupported_type"
            }
        }
    }

    private static func payload(for snapshot: CompactControlSnapshot?) -> [String: Any]? {
        guard let snapshot,
              let data = try? JSONEncoder().encode(snapshot) else {
            return nil
        }
        return ["type": "snapshot", "snapshot": data]
    }

}
#else
final class Gate3WatchConnectivityController {
    private(set) var activationState = "unsupported"
    private(set) var lastMessage = "none"

    func activate(
        snapshotProvider: @escaping @MainActor () -> CompactControlSnapshot?,
        commandHandler: @escaping @MainActor (Gate3WatchCommandRequest) -> Void
    ) {}

    func publish(snapshot: CompactControlSnapshot?) {}

    func diagnostics() -> [String: String] {
        [
            "gate3WatchConnectivity": activationState,
            "gate3WatchReachable": "false",
            "gate3WatchLastMessage": lastMessage
        ]
    }
}
#endif
