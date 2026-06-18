import Foundation
import SessionKit
import SessionKitAudio
@preconcurrency import WatchConnectivity

@MainActor
final class WatchTetheredModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var snapshot: CompactControlSnapshot?
    @Published var status = "Connecting"
    @Published var lastError: String?
    @Published private var optimisticRecording = false
    @Published var packageRows: [WatchPackageLibraryRow] = []
    @Published var activePackage: WatchAudioPackage?
    @Published var untetheredSnapshot: SessionSnapshot?
    @Published var pendingSyncEventCount = 0
    @Published var isUntetheredRecording = false

    private struct IncomingPayload: Sendable {
        var type: String?
        var snapshotData: Data?
        var rowsData: Data?
        var packageData: Data?
        var errorMessage: String?
    }

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let packageStore = WatchPackageStore()
    private let preparedAudio = PreparedAudioPlaybackClient()
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
    private var localEngine: SessionEngine?
    private var localPackages: [String: WatchAudioPackage] = [:]
    private var playbackProgressTask: Task<Void, Never>?

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
        reloadLocalPackages()
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

    var isUntetheredPlaying: Bool {
        untetheredSnapshot?.status == .playing
    }

    var canSendCommands: Bool {
        snapshot?.compactSurfaceReady == true
    }

    var needsPhoneToResume: Bool {
        !isReachable && snapshot?.status != .playing
    }

    var timeline: [CompactTimelineEntry] {
        snapshot?.timeline ?? []
    }

    var hasTimeline: Bool {
        !timeline.isEmpty
    }

    var activePackageChapters: [MediaTimelineChapter] {
        activePackage?.chapters.sorted { $0.startMs < $1.startMs } ?? []
    }

    var untetheredTitle: String {
        activePackage?.item.title ?? "No package loaded"
    }

    var untetheredProgressText: String {
        guard let untetheredSnapshot else { return "Choose a package" }
        return "\(untetheredSnapshot.sourceProgressPercent)% source"
    }

    func canSend(_ command: CompactControlCommand) -> Bool {
        if command == .beginInterjection {
            return false
        }
        if optimisticRecording {
            switch command {
            case .finishInterjection, .cancelInterjection:
                return canSendCommands && isReachable
            case .beginInterjection:
                return false
            default:
                break
            }
        }
        guard canSendCommands else { return false }
        if needsPhoneToResume {
            switch command {
            case .play, .togglePlayPause, .skipBack, .skipForward, .jumpToChapter, .beginInterjection:
                return false
            default:
                break
            }
        }
        if requiresLivePhone(command), !isReachable {
            return false
        }
        return snapshot?.availableCommands.contains(command) == true
    }

    func refresh() {
        send(message: ["type": "requestSnapshot"], allowQueue: false)
        requestPackageLibrary()
    }

    func requestPackageLibrary() {
        send(message: ["type": "requestPackageLibrary"], allowQueue: false)
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

    func selectPackageRow(_ row: WatchPackageLibraryRow) {
        switch row.status {
        case .loadedOnWatch:
            guard let packageId = row.packageId else { return }
            loadLocalPackage(packageId: packageId)
        case .availableForTransfer, .queuedForTransfer:
            guard let packageId = row.packageId else { return }
            sendPackageRequest(
                itemId: row.itemId,
                packageId: packageId,
                requestType: .watchTransferRequested
            )
        case .needsPrerender, .rendering:
            sendPackageRequest(
                itemId: row.itemId,
                packageId: row.packageId,
                requestType: .prerenderRequested
            )
        case .failed, .expired:
            status = "Package unavailable"
        }
    }

    func loadLocalPackage(packageId: String) {
        do {
            guard let package = localPackages[packageId] else {
                throw SessionKitError.missingFixture("watch_package:\(packageId)")
            }
            if let asset = package.primaryAudioAsset,
               let url = packageStore.audioURL(for: package, asset: asset),
               packageStore.fileExists(at: url) {
                try preparedAudio.prepareAudioFile(
                    targetId: asset.audioAssetId,
                    fileURL: url,
                    durationMs: asset.durationMs
                )
            }
            let repository = InMemorySessionRepository(watchPackages: [package.id: package])
            let engine = SessionEngine(
                profile: Self.watchUntetheredProfile,
                repository: repository,
                audio: preparedAudio,
                recorder: SystemRecordingClient(baseDirectory: packageStore.rootDirectory)
            )
            localEngine = engine
            activePackage = package
            untetheredSnapshot = try engine.loadWatchPackage(watchPackageId: package.id)
            status = packageStore.packageHasPrimaryAudio(package) ? "Package loaded" : "Package loaded, audio missing"
            lastError = nil
            mergePackageRows(packageRows)
        } catch {
            lastError = error.localizedDescription
            status = "Package load failed"
        }
    }

    func toggleUntetheredPlayback() {
        runLocalEngineCommand("Playback") { engine in
            try engine.togglePlayPause()
        }
    }

    func skipUntetheredBack() {
        runLocalEngineCommand("Skip back") { engine in
            try engine.skipBack(unit: "previous_segment")
        }
    }

    func skipUntetheredForward() {
        runLocalEngineCommand("Skip forward") { engine in
            try engine.skipForward(unit: "next_segment")
        }
    }

    func jumpUntethered(to chapterId: String) {
        runLocalEngineCommand("Chapter jump") { engine in
            try engine.jumpToChapter(chapterId: chapterId)
        }
    }

    func beginUntetheredInterjection() {
        Task {
            let granted = await SystemRecordingClient.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.lastError = "Microphone access required"
                    self.status = "Recording blocked"
                }
                return
            }
            await MainActor.run {
                self.runLocalEngineCommand("Begin interjection") { engine in
                    try engine.beginInterjection()
                }
                self.isUntetheredRecording = self.untetheredSnapshot?.isRecording == true
            }
        }
    }

    func finishUntetheredInterjection() {
        runLocalEngineCommand("Finish interjection") { engine in
            let snapshot = try engine.finishInterjection(audioRef: nil)
            if let event = engine.lastQueuedWatchSyncEvent {
                sendWatchSyncEvent(event)
            }
            return snapshot
        }
        isUntetheredRecording = false
    }

    func cancelUntetheredInterjection() {
        runLocalEngineCommand("Cancel interjection") { engine in
            try engine.cancelInterjection()
        }
        isUntetheredRecording = false
    }

    private func runLocalEngineCommand(_ label: String, _ command: (SessionEngine) throws -> SessionSnapshot) {
        guard let engine = localEngine else {
            status = "Load a package first"
            return
        }
        do {
            untetheredSnapshot = try command(engine)
            isUntetheredRecording = untetheredSnapshot?.isRecording == true
            status = "\(label) ready"
            lastError = nil
            reconcileUntetheredProgressTicker()
        } catch {
            lastError = error.localizedDescription
            status = "\(label) failed"
        }
    }

    private func send(_ command: CompactControlCommand, extra: [String: Any]) {
        guard canSend(command) else {
            status = unavailableStatus(for: command)
            optimisticRecording = false
            return
        }
        applyOptimisticState(for: command)
        var message = extra
        message["type"] = "command"
        message["command"] = command.rawValue
        send(message: message, allowQueue: true)
    }

    private func sendPackageRequest(itemId: String, packageId: String?, requestType: WatchPackageRequestType) {
        let requestId = "watch-request-\(UUID().uuidString)"
        var message: [String: Any] = [
            "type": "requestWatchPackage",
            "requestId": requestId,
            "itemId": itemId,
            "requestType": requestType.rawValue
        ]
        if let packageId {
            message["packageId"] = packageId
        }
        send(message: message, allowQueue: true)
        markRowQueued(itemId: itemId, packageId: packageId, requestType: requestType)
    }

    private func sendWatchSyncEvent(_ event: WatchSyncEvent) {
        do {
            let data = try encoder.encode(event)
            let message: [String: Any] = ["type": "watchSyncEvent", "event": data]
            send(message: message, allowQueue: true)
            if let audioFileName = event.payload.audioFileName,
               let audioURL = packageStore.recordingURL(fileName: audioFileName) {
                session?.transferFile(
                    audioURL,
                    metadata: [
                        "type": "watchSyncAudio",
                        "eventId": event.id,
                        "fileName": audioFileName
                    ]
                )
            }
            pendingSyncEventCount += 1
            status = "Interjection queued"
        } catch {
            lastError = error.localizedDescription
            status = "Sync event encode failed"
        }
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

    private func requiresLivePhone(_ command: CompactControlCommand) -> Bool {
        switch command {
        case .beginInterjection, .finishInterjection, .cancelInterjection, .generateInterjectionSummary, .submitFollowup:
            return true
        case .play, .pause, .togglePlayPause, .skipBack, .skipForward, .jumpToChapter:
            return false
        }
    }

    private func unavailableStatus(for command: CompactControlCommand) -> String {
        if requiresLivePhone(command), !isReachable {
            switch command {
            case .beginInterjection, .finishInterjection, .cancelInterjection:
                return "Open iPhone to interject"
            case .generateInterjectionSummary, .submitFollowup:
                return "Open iPhone for AI"
            default:
                return "Open iPhone app"
            }
        }
        return "Command unavailable"
    }

    private func send(message: [String: Any], allowQueue: Bool) {
        guard let session else {
            status = "WatchConnectivity unavailable"
            return
        }
        guard session.activationState == .activated else {
            status = "Pairing"
            session.activate()
            if allowQueue {
                session.transferUserInfo(message)
            }
            return
        }
        guard session.isReachable else {
            if allowQueue {
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

    private func reloadLocalPackages() {
        do {
            let packages = try packageStore.loadPackages()
            localPackages = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
            mergePackageRows(packageRows)
        } catch {
            lastError = error.localizedDescription
            status = "Package scan failed"
        }
    }

    private func mergePackageRows(_ remoteRows: [WatchPackageLibraryRow]) {
        var merged: [WatchPackageLibraryRow] = remoteRows.map { row in
            if let packageId = row.packageId, localPackages[packageId] != nil {
                return WatchPackageLibraryRow(
                    itemId: row.itemId,
                    title: row.title,
                    status: .loadedOnWatch,
                    packageId: packageId,
                    progressPercent: nil
                )
            }
            return row
        }
        let knownPackageIds = Set(merged.compactMap(\.packageId))
        for package in localPackages.values where !knownPackageIds.contains(package.id) {
            merged.append(
                WatchPackageLibraryRow(
                    itemId: package.itemId,
                    title: package.item.title,
                    status: .loadedOnWatch,
                    packageId: package.id
                )
            )
        }
        packageRows = merged.sorted { lhs, rhs in
            if lhs.status == rhs.status {
                return lhs.title < rhs.title
            }
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
    }

    private func statusRank(_ status: WatchPackageLibraryStatus) -> Int {
        switch status {
        case .loadedOnWatch: return 0
        case .queuedForTransfer: return 1
        case .availableForTransfer: return 2
        case .needsPrerender: return 3
        case .rendering: return 4
        case .failed: return 5
        case .expired: return 6
        }
    }

    private func markRowQueued(itemId: String, packageId: String?, requestType: WatchPackageRequestType) {
        packageRows = packageRows.map { row in
            guard row.itemId == itemId, row.packageId == packageId else { return row }
            return WatchPackageLibraryRow(
                itemId: row.itemId,
                title: row.title,
                status: requestType == .prerenderRequested ? .rendering : .queuedForTransfer,
                packageId: row.packageId,
                progressPercent: 0
            )
        }
    }

    private func handleWatchPackage(data: Data) {
        do {
            let package = try decoder.decode(WatchAudioPackage.self, from: data)
            try packageStore.savePackage(package, manifestData: data)
            localPackages[package.id] = package
            mergePackageRows(packageRows)
            status = "Package received"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = "Package import failed"
        }
    }

    private func reconcileUntetheredProgressTicker() {
        guard untetheredSnapshot?.status == .playing else {
            playbackProgressTask?.cancel()
            playbackProgressTask = nil
            return
        }
        guard playbackProgressTask == nil else { return }
        playbackProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    guard let self, let engine = self.localEngine else { return }
                    do {
                        self.untetheredSnapshot = try engine.syncPlaybackProgress()
                        if self.untetheredSnapshot?.status != .playing {
                            self.playbackProgressTask?.cancel()
                            self.playbackProgressTask = nil
                        }
                    } catch {
                        self.lastError = error.localizedDescription
                    }
                }
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

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let payload = Self.payload(from: userInfo)
        Task { @MainActor [weak self] in
            self?.handle(payload)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let type = metadata["type"] as? String
        let data = type == "watchPackageFile" ? try? Data(contentsOf: file.fileURL) : nil
        let packageId = metadata["packageId"] as? String
        let fileName = metadata["fileName"] as? String
        let fileURL = file.fileURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            if type == "watchPackageFile" {
                guard let data else {
                    self.status = "Package file unreadable"
                    return
                }
                self.handleWatchPackage(data: data)
                return
            }
            if type == "watchPackageAsset",
               let packageId,
               let fileName {
                do {
                    try self.packageStore.saveAsset(packageId: packageId, fileName: fileName, temporaryURL: fileURL)
                    self.reloadLocalPackages()
                    self.status = "Audio received"
                } catch {
                    self.lastError = error.localizedDescription
                    self.status = "Audio import failed"
                }
            }
        }
    }

    nonisolated private static func payload(from message: [String: Any]) -> IncomingPayload {
        IncomingPayload(
            type: message["type"] as? String,
            snapshotData: message["snapshot"] as? Data,
            rowsData: message["rows"] as? Data,
            packageData: message["package"] as? Data,
            errorMessage: message["error"] as? String
        )
    }

    private func handle(_ payload: IncomingPayload) {
        guard let type = payload.type else { return }
        switch type {
        case "snapshot":
            guard let data = payload.snapshotData else { return }
            do {
                snapshot = try decoder.decode(CompactControlSnapshot.self, from: data)
                optimisticRecording = snapshot?.isRecording == true
                status = "Ready"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                status = "Decode failed"
            }
        case "watchPackageLibrary":
            guard let data = payload.rowsData else { return }
            do {
                let rows = try decoder.decode([WatchPackageLibraryRow].self, from: data)
                mergePackageRows(rows)
                status = "Library synced"
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                status = "Library decode failed"
            }
        case "watchPackage":
            if let data = payload.packageData {
                handleWatchPackage(data: data)
            }
        case "error":
            lastError = payload.errorMessage
            status = "Phone error"
        default:
            break
        }
    }

    private static let watchUntetheredProfile = RuntimeCapabilityProfile(
        id: "watch-untethered",
        displayName: "Watch Untethered",
        capabilities: [
            "playback": ["prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing", "playback_rate_observation"],
            "interjection": ["record_audio", "capture_transcript_anchor", "capture_media_anchor", "queue_offline_interjections"],
            "ai": [],
            "sync": ["queue_offline_events", "receive_prepared_packages"],
            "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands"]
        ],
        forbiddenCapabilities: ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"]
    )
}

private final class WatchPackageStore {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        rootDirectory = support.appending(path: "SpokenMarginsWatch", directoryHint: .isDirectory)
    }

    func loadPackages() throws -> [WatchAudioPackage] {
        let packagesDirectory = rootDirectory.appending(path: "packages", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: packagesDirectory.path) else { return [] }
        let packageDirectories = try fileManager.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try packageDirectories.compactMap { directory in
            let manifest = directory.appending(path: "manifest.json")
            guard fileManager.fileExists(atPath: manifest.path) else { return nil }
            let data = try Data(contentsOf: manifest)
            return try decoder.decode(WatchAudioPackage.self, from: data)
        }
    }

    func savePackage(_ package: WatchAudioPackage, manifestData: Data) throws {
        let directory = packageDirectory(package.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifestData.write(to: directory.appending(path: "manifest.json"), options: .atomic)
    }

    func saveAsset(packageId: String, fileName: String, temporaryURL: URL) throws {
        let directory = packageDirectory(packageId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: fileName)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: temporaryURL, to: destination)
    }

    func audioURL(for package: WatchAudioPackage, asset: WatchPackageAudioAsset) -> URL? {
        packageDirectory(package.id).appending(path: asset.fileName)
    }

    func packageHasPrimaryAudio(_ package: WatchAudioPackage) -> Bool {
        guard let asset = package.primaryAudioAsset,
              let url = audioURL(for: package, asset: asset) else {
            return false
        }
        return fileExists(at: url)
    }

    func recordingURL(fileName: String) -> URL? {
        let directory = rootDirectory.appending(path: "interjections", directoryHint: .isDirectory)
        let direct = directory.appending(path: fileName)
        if fileExists(at: direct) {
            return direct
        }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }
        return nil
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func packageDirectory(_ packageId: String) -> URL {
        rootDirectory
            .appending(path: "packages", directoryHint: .isDirectory)
            .appending(path: packageId, directoryHint: .isDirectory)
    }
}
