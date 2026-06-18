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
    private var packageLibraryProvider: (@MainActor () -> [WatchPackageLibraryRow])?
    private var packageProvider: (@MainActor (String) throws -> WatchAudioPackage?)?
    private var packageRequestHandler: (@MainActor (WatchPackageRequestEvent) -> Void)?
    private var watchSyncEventHandler: (@MainActor (WatchSyncEvent) -> Void)?
    private var session: WCSession?
    private(set) var activationState = "inactive"
    private(set) var lastMessage = "none"
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func activate(
        snapshotProvider: @escaping @MainActor () -> CompactControlSnapshot?,
        commandHandler: @escaping @MainActor (Gate3WatchCommandRequest) -> Void,
        packageLibraryProvider: @escaping @MainActor () -> [WatchPackageLibraryRow] = { [] },
        packageProvider: @escaping @MainActor (String) throws -> WatchAudioPackage? = { _ in nil },
        packageRequestHandler: @escaping @MainActor (WatchPackageRequestEvent) -> Void = { _ in },
        watchSyncEventHandler: @escaping @MainActor (WatchSyncEvent) -> Void = { _ in }
    ) {
        guard WCSession.isSupported() else {
            activationState = "unsupported"
            return
        }
        self.snapshotProvider = snapshotProvider
        self.commandHandler = commandHandler
        self.packageLibraryProvider = packageLibraryProvider
        self.packageProvider = packageProvider
        self.packageRequestHandler = packageRequestHandler
        self.watchSyncEventHandler = watchSyncEventHandler
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

    func publishPackageLibrary() {
        guard let rows = packageLibraryProvider?(),
              let data = try? encoder.encode(rows) else {
            lastMessage = "package_library_empty"
            return
        }
        let payload: [String: Any] = ["type": "watchPackageLibrary", "rows": data]
        if session?.isReachable == true {
            session?.sendMessage(payload, replyHandler: nil)
        } else {
            session?.transferUserInfo(payload)
        }
        lastMessage = "package_library_sent"
    }

    func transferWatchPackage(packageId: String) {
        do {
            guard let package = try packageProvider?(packageId) else {
                lastMessage = "watch_package_missing:\(packageId)"
                return
            }
            let data = try encoder.encode(package)
            let payload: [String: Any] = ["type": "watchPackage", "package": data]
            if session?.isReachable == true {
                session?.sendMessage(payload, replyHandler: nil)
            }
            let fileURL = try writeTransferManifest(package: package, data: data)
            session?.transferFile(
                fileURL,
                metadata: ["type": "watchPackageFile", "packageId": package.id]
            )
            for asset in package.audioAssets {
                if let assetURL = locatePackageAsset(fileName: asset.fileName) {
                    session?.transferFile(
                        assetURL,
                        metadata: [
                            "type": "watchPackageAsset",
                            "packageId": package.id,
                            "fileName": asset.fileName
                        ]
                    )
                }
            }
            lastMessage = "watch_package_transfer_started"
        } catch {
            lastMessage = "watch_package_transfer_failed:\(error.localizedDescription)"
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
        handleIncoming(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let metadata = file.metadata ?? [:]
            if metadata["type"] as? String == "watchSyncAudio" {
                do {
                    let fileName = metadata["fileName"] as? String ?? file.fileURL.lastPathComponent
                    let destination = try self.watchSyncAudioDestination(fileName: fileName)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: file.fileURL, to: destination)
                    self.lastMessage = "watch_sync_audio_received:\(fileName)"
                } catch {
                    self.lastMessage = "watch_sync_audio_failed:\(error.localizedDescription)"
                }
            } else {
                self.lastMessage = "unexpected_watch_file:\(file.fileURL.lastPathComponent)"
            }
        }
    }

    nonisolated private func handleIncoming(_ message: [String: Any]) {
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
        case "requestPackageLibrary":
            Task { @MainActor [weak self] in
                self?.publishPackageLibrary()
            }
        case "requestWatchPackage":
            let requestId = message["requestId"] as? String
            let itemId = message["itemId"] as? String
            let packageId = message["packageId"] as? String
            let requestType = message["requestType"] as? String
            Task { @MainActor [weak self] in
                guard let self else { return }
                let request = WatchPackageRequestEvent(
                    id: requestId ?? "watch-request-\(UUID().uuidString)",
                    itemId: itemId ?? "",
                    packageId: packageId,
                    requestType: WatchPackageRequestType(rawValue: requestType ?? "") ?? .watchTransferRequested,
                    createdAt: Date()
                )
                self.packageRequestHandler?(request)
                if request.requestType == .watchTransferRequested, let packageId = request.packageId {
                    self.transferWatchPackage(packageId: packageId)
                }
                self.publishPackageLibrary()
            }
        case "watchSyncEvent":
            guard let data = message["event"] as? Data else {
                Task { @MainActor [weak self] in
                    self?.lastMessage = "watch_sync_event_missing_payload"
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let event = try self.decoder.decode(WatchSyncEvent.self, from: data)
                    self.watchSyncEventHandler?(event)
                    self.lastMessage = "watch_sync_event_received"
                } catch {
                    self.lastMessage = "watch_sync_event_decode_failed:\(error.localizedDescription)"
                }
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

    private func writeTransferManifest(package: WatchAudioPackage, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SpokenMarginsWatchTransfers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "\(package.id).watch-package.json")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func locatePackageAsset(fileName: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: (fileName as NSString).pathExtension) {
            return bundleURL
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let candidates = [
            support?.appending(path: "SpokenMargins/watch-audio").appending(path: fileName),
            support?.appending(path: "SpokenMargins/audio").appending(path: fileName),
            support?.appending(path: fileName)
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func watchSyncAudioDestination(fileName: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appending(path: "SpokenMargins/interjections", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: fileName)
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
        commandHandler: @escaping @MainActor (Gate3WatchCommandRequest) -> Void,
        packageLibraryProvider: @escaping @MainActor () -> [WatchPackageLibraryRow] = { [] },
        packageProvider: @escaping @MainActor (String) throws -> WatchAudioPackage? = { _ in nil },
        packageRequestHandler: @escaping @MainActor (WatchPackageRequestEvent) -> Void = { _ in },
        watchSyncEventHandler: @escaping @MainActor (WatchSyncEvent) -> Void = { _ in }
    ) {}

    func publish(snapshot: CompactControlSnapshot?) {}

    func publishPackageLibrary() {}

    func transferWatchPackage(packageId: String) {}

    func diagnostics() -> [String: String] {
        [
            "gate3WatchConnectivity": activationState,
            "gate3WatchReachable": "false",
            "gate3WatchLastMessage": lastMessage
        ]
    }
}
#endif
