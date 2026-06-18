import Foundation
import SessionKit
import SessionKitAudio
@preconcurrency import WatchConnectivity

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
final class WatchOfflineLibraryModel: ObservableObject {
    @Published var packageRows: [WatchPackageLibraryRow] = []
    @Published var status = "Offline items"
    @Published var lastError: String?
    @Published private(set) var isReachable = false

    private let packageStore: WatchPackageStore
    private var localPackages: [String: WatchAudioPackage] = [:]
    private weak var connectivity: WatchConnectivityInbox?

    init(packageStore: WatchPackageStore = WatchPackageStore()) {
        self.packageStore = packageStore
        loadCachedPackageRows()
        reloadLocalPackages()
    }

    func attach(connectivity: WatchConnectivityInbox) {
        self.connectivity = connectivity
        isReachable = connectivity.isReachable
    }

    func setReachable(_ reachable: Bool) {
        isReachable = reachable
        status = reachable ? "Phone reachable" : "Offline items"
    }

    func refresh() {
        reloadLocalPackages()
        guard isReachable else {
            status = packageRows.isEmpty ? "Open iPhone to sync packages" : "Offline items ready"
            return
        }
        connectivity?.requestPackageLibrary()
    }

    func selectPackageRow(_ row: WatchPackageLibraryRow, playback: WatchLocalPlaybackModel) {
        reloadLocalPackages()
        if let packageId = row.packageId,
           let package = localPackages[packageId],
           packageStore.packageHasPrimaryAudio(package) {
            playback.load(package: package)
            mergePackageRows(packageRows)
            return
        }

        switch row.status {
        case .loadedOnWatch, .availableForTransfer, .queuedForTransfer:
            requestTransfer(row)
        case .needsPrerender, .rendering:
            requestRender(row)
        case .failed, .expired:
            status = "Package unavailable"
        }
    }

    func requestRender(_ row: WatchPackageLibraryRow) {
        connectivity?.sendPackageRequest(
            itemId: row.itemId,
            packageId: row.packageId,
            requestType: .prerenderRequested
        )
        markRowQueued(itemId: row.itemId, packageId: row.packageId, requestType: .prerenderRequested)
    }

    func requestTransfer(_ row: WatchPackageLibraryRow) {
        guard let packageId = row.packageId else {
            status = "Package unavailable"
            return
        }
        connectivity?.sendPackageRequest(
            itemId: row.itemId,
            packageId: packageId,
            requestType: .watchTransferRequested
        )
        markRowQueued(itemId: row.itemId, packageId: packageId, requestType: .watchTransferRequested)
    }

    func handlePackageRows(_ rows: [WatchPackageLibraryRow]) {
        mergePackageRows(rows)
        status = "Library synced"
        lastError = nil
    }

    func handlePackageManifest(_ package: WatchAudioPackage, manifestData: Data) {
        do {
            try packageStore.savePackage(package, manifestData: manifestData)
            localPackages[package.id] = package
            mergePackageRows(packageRows)
            status = "Package received"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = "Package import failed"
        }
    }

    func handlePackageAsset(packageId: String, fileName: String, temporaryURL: URL) {
        do {
            try packageStore.saveAsset(packageId: packageId, fileName: fileName, temporaryURL: temporaryURL)
            reloadLocalPackages()
            status = "Audio received"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = "Audio import failed"
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

    private func loadCachedPackageRows() {
        do {
            packageRows = try packageStore.loadPackageRows()
        } catch {
            lastError = error.localizedDescription
            status = "Package cache failed"
        }
    }

    private func mergePackageRows(_ remoteRows: [WatchPackageLibraryRow]) {
        var merged: [WatchPackageLibraryRow] = remoteRows.map { row in
            if let packageId = row.packageId,
               let package = localPackages[packageId],
               packageStore.packageHasPrimaryAudio(package) {
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
            let status: WatchPackageLibraryStatus = packageStore.packageHasPrimaryAudio(package) ? .loadedOnWatch : .queuedForTransfer
            merged.append(
                WatchPackageLibraryRow(
                    itemId: package.itemId,
                    title: package.item.title,
                    status: status,
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
        try? packageStore.savePackageRows(packageRows)
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
        try? packageStore.savePackageRows(packageRows)
    }
}

@MainActor
final class WatchLocalPlaybackModel: ObservableObject {
    @Published var activePackage: WatchAudioPackage?
    @Published var snapshot: SessionSnapshot?
    @Published var status = "Choose an item"
    @Published var lastError: String?
    @Published var pendingSyncEventCount = 0
    @Published var isRecording = false
    @Published private(set) var audioReady = false

    private let packageStore: WatchPackageStore
    private let preparedAudio = PreparedAudioPlaybackClient()
    private var localEngine: SessionEngine?
    private var playbackProgressTask: Task<Void, Never>?
    private var syncEventHandler: ((WatchSyncEvent) -> Void)?

    init(packageStore: WatchPackageStore = WatchPackageStore()) {
        self.packageStore = packageStore
    }

    var isPlaying: Bool {
        snapshot?.status == .playing
    }

    var title: String {
        activePackage?.item.title ?? "No package loaded"
    }

    var progressText: String {
        guard let snapshot else { return "Choose a package" }
        return "\(snapshot.sourceProgressPercent)% source"
    }

    var chapters: [MediaTimelineChapter] {
        guard let package = activePackage else { return [] }
        let chapters = package.chapters.sorted { $0.startMs < $1.startMs }
        if !chapters.isEmpty {
            return chapters
        }
        return package.transcript.segments
            .sorted { $0.startMs < $1.startMs }
            .enumerated()
            .map { index, segment in
                MediaTimelineChapter(
                    id: "segment-chapter-\(segment.id)",
                    title: fallbackChapterTitle(segment.text, index: index),
                    startMs: segment.startMs,
                    transcriptSegmentId: segment.id
                )
            }
    }

    func attachSyncEventHandler(_ handler: @escaping (WatchSyncEvent) -> Void) {
        syncEventHandler = handler
    }

    func clearActivePackage() {
        if let localEngine {
            do {
                try localEngine.stopPlayback()
            } catch {
                status = "Playback stopped"
            }
        }
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
        activePackage = nil
        snapshot = nil
        localEngine = nil
        audioReady = false
        isRecording = false
        status = "Choose an item"
        lastError = nil
    }

    func load(package: WatchAudioPackage) {
        do {
            audioReady = false
            guard let asset = package.primaryAudioAsset,
                  let url = packageStore.audioURL(for: package, asset: asset),
                  packageStore.fileExists(at: url) else {
                throw SessionKitError.persistenceFailed("watch_package_audio_missing:\(package.id)")
            }
            try preparedAudio.prepareAudioFile(
                targetId: asset.audioAssetId,
                fileURL: url,
                durationMs: asset.durationMs
            )
            let repository = InMemorySessionRepository(watchPackages: [package.id: package])
            let engine = SessionEngine(
                profile: Self.watchUntetheredProfile,
                repository: repository,
                audio: preparedAudio,
                recorder: SystemRecordingClient(baseDirectory: packageStore.rootDirectory)
            )
            localEngine = engine
            activePackage = package
            snapshot = try engine.loadWatchPackage(watchPackageId: package.id)
            audioReady = true
            status = "Package loaded"
            lastError = nil
        } catch {
            clearActivePackage()
            lastError = error.localizedDescription
            status = "Package load failed"
        }
    }

    func togglePlayback() {
        runLocalCommand("Playback") { engine in
            try engine.togglePlayPause()
        }
    }

    func skipBack() {
        runLocalCommand("Skip back") { engine in
            try engine.skipBack(unit: "previous_segment")
        }
    }

    func skipForward() {
        runLocalCommand("Skip forward") { engine in
            try engine.skipForward(unit: "next_segment")
        }
    }

    func jump(to chapterId: String) {
        runLocalCommand("Chapter jump") { engine in
            try engine.jumpToChapter(chapterId: chapterId)
        }
    }

    func beginInterjection() {
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
                self.runLocalCommand("Begin interjection") { engine in
                    try engine.beginInterjection()
                }
                self.isRecording = self.snapshot?.isRecording == true
            }
        }
    }

    func finishInterjection() {
        runLocalCommand("Finish interjection") { engine in
            let snapshot = try engine.finishInterjection(audioRef: nil)
            if let event = engine.lastQueuedWatchSyncEvent {
                syncEventHandler?(event)
                pendingSyncEventCount += 1
            }
            return snapshot
        }
        isRecording = false
    }

    func cancelInterjection() {
        runLocalCommand("Cancel interjection") { engine in
            try engine.cancelInterjection()
        }
        isRecording = false
    }

    private func runLocalCommand(_ label: String, _ command: (SessionEngine) throws -> SessionSnapshot) {
        guard let engine = localEngine else {
            status = "Load a package first"
            return
        }
        do {
            snapshot = try command(engine)
            isRecording = snapshot?.isRecording == true
            status = "\(label) ready"
            lastError = nil
            reconcileProgressTicker()
        } catch {
            lastError = error.localizedDescription
            status = "\(label) failed"
        }
    }

    private func reconcileProgressTicker() {
        guard snapshot?.status == .playing else {
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
                        self.snapshot = try engine.syncPlaybackProgress()
                        if self.snapshot?.status != .playing {
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

    private func fallbackChapterTitle(_ text: String, index: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "Segment \(index + 1)"
        }
        let words = normalized.split(separator: " ").prefix(5).joined(separator: " ")
        return words.isEmpty ? "Segment \(index + 1)" : words
    }

    private static let watchUntetheredProfile = RuntimeCapabilityProfile(
        id: "watch-untethered",
        displayName: "Watch Untethered",
        capabilities: [
            "playback": ["prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing", "playback_rate_observation"],
            "interjection": ["record_audio", "capture_transcript_anchor", "capture_media_anchor", "queue_offline_interjections"],
            "ai": [],
            "sync": ["queue_offline_events", "receive_prepared_packages"]
        ],
        forbiddenCapabilities: ["realtime_tts", "assistant_turn_tts", "summary_turn_tts", "send_transport_commands"]
    )
}

@MainActor
final class WatchConnectivityInbox: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var isReachable = false
    @Published private(set) var status = "Connecting"
    @Published private(set) var lastMessage = "none"

    private struct IncomingPayload: Sendable {
        var type: String?
        var rowsData: Data?
        var packageData: Data?
        var errorMessage: String?
    }

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil
    private let packageStore = WatchPackageStore()
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
    private weak var libraryModel: WatchOfflineLibraryModel?
    private weak var playbackModel: WatchLocalPlaybackModel?

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    func attach(library: WatchOfflineLibraryModel, playback: WatchLocalPlaybackModel) {
        libraryModel = library
        playbackModel = playback
        library.attach(connectivity: self)
        playback.attachSyncEventHandler { [weak self] event in
            self?.sendWatchSyncEvent(event)
        }
        isReachable = session?.isReachable == true
        library.setReachable(isReachable)
        handle(Self.payload(from: session?.receivedApplicationContext ?? [:]))
    }

    func requestPackageLibrary() {
        send(message: ["type": "requestPackageLibrary"], allowQueue: false)
    }

    func sendPackageRequest(itemId: String, packageId: String?, requestType: WatchPackageRequestType) {
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
    }

    private func sendWatchSyncEvent(_ event: WatchSyncEvent) {
        do {
            let data = try encoder.encode(event)
            let message: [String: Any] = ["type": "watchSyncEvent", "event": data]
            send(message: message, allowQueue: true)
            if let audioFileName = event.payload.audioFileName,
               let audioURL = packageStore.recordingURL(fileName: audioFileName),
               packageStore.fileExists(at: audioURL) {
                session?.transferFile(
                    audioURL,
                    metadata: [
                        "type": "watchSyncAudio",
                        "eventId": event.id,
                        "fileName": audioFileName
                    ]
                )
            }
            lastMessage = "watch_sync_event_queued"
        } catch {
            lastMessage = "watch_sync_event_encode_failed:\(error.localizedDescription)"
        }
    }

    private func send(message: [String: Any], allowQueue: Bool) {
        guard let session else {
            status = "WatchConnectivity unavailable"
            lastMessage = "unsupported"
            return
        }
        guard session.activationState == .activated else {
            status = "Pairing"
            session.activate()
            if allowQueue {
                session.transferUserInfo(message)
                lastMessage = "queued_before_activation"
            }
            return
        }
        guard session.isReachable else {
            if allowQueue {
                session.transferUserInfo(message)
                status = "Queued for iPhone"
                lastMessage = "queued_for_phone"
                return
            }
            status = "Open iPhone to sync"
            lastMessage = "phone_unreachable"
            return
        }
        status = "Sending"
        lastMessage = message["type"] as? String ?? "sent"
        session.sendMessage(message, replyHandler: nil) { [weak self] error in
            Task { @MainActor in
                self?.status = "Send failed"
                self?.lastMessage = error.localizedDescription
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = error.map { "Activation failed: \($0.localizedDescription)" } ?? "Connected"
            self.isReachable = session.isReachable
            self.libraryModel?.setReachable(session.isReachable)
            self.handle(Self.payload(from: session.receivedApplicationContext))
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isReachable = session.isReachable
            self.status = session.isReachable ? "Connected" : "Offline"
            self.libraryModel?.setReachable(session.isReachable)
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
                self.handlePackage(data: data)
                return
            }
            if type == "watchPackageAsset",
               let packageId,
               let fileName {
                self.libraryModel?.handlePackageAsset(packageId: packageId, fileName: fileName, temporaryURL: fileURL)
                self.status = "Audio received"
            }
        }
    }

    private nonisolated static func payload(from message: [String: Any]) -> IncomingPayload {
        IncomingPayload(
            type: message["type"] as? String,
            rowsData: message["rows"] as? Data,
            packageData: message["package"] as? Data,
            errorMessage: message["error"] as? String
        )
    }

    private func handle(_ payload: IncomingPayload) {
        guard let type = payload.type else { return }
        switch type {
        case "watchPackageLibrary":
            guard let data = payload.rowsData else { return }
            do {
                let rows = try decoder.decode([WatchPackageLibraryRow].self, from: data)
                libraryModel?.handlePackageRows(rows)
                lastMessage = "library_synced"
            } catch {
                status = "Library decode failed"
                lastMessage = error.localizedDescription
            }
        case "watchPackage":
            if let data = payload.packageData {
                handlePackage(data: data)
            }
        case "error":
            status = "Phone error"
            lastMessage = payload.errorMessage ?? "unknown_error"
        default:
            break
        }
    }

    private func handlePackage(data: Data) {
        do {
            let package = try decoder.decode(WatchAudioPackage.self, from: data)
            libraryModel?.handlePackageManifest(package, manifestData: data)
            lastMessage = "package_received"
        } catch {
            status = "Package import failed"
            lastMessage = error.localizedDescription
        }
    }
}

final class WatchPackageStore {
    let rootDirectory: URL
    private let fileManager: FileManager
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

    func loadPackageRows() throws -> [WatchPackageLibraryRow] {
        let url = packageRowsURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([WatchPackageLibraryRow].self, from: data)
    }

    func savePackageRows(_ rows: [WatchPackageLibraryRow]) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(rows)
        try data.write(to: packageRowsURL(), options: .atomic)
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
              let url = audioURL(for: package, asset: asset),
              fileExists(at: url) else {
            return false
        }
        #if canImport(AVFoundation)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return false
        }
        return player.duration > 0
        #else
        return true
        #endif
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func recordingURL(fileName: String) -> URL? {
        let candidates = [
            rootDirectory.appending(path: fileName),
            rootDirectory.appending(path: "interjections", directoryHint: .isDirectory).appending(path: fileName),
            rootDirectory.appending(path: "Recordings", directoryHint: .isDirectory).appending(path: fileName),
            rootDirectory.appending(path: "recordings", directoryHint: .isDirectory).appending(path: fileName)
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    private func packageDirectory(_ packageId: String) -> URL {
        rootDirectory
            .appending(path: "packages", directoryHint: .isDirectory)
            .appending(path: packageId, directoryHint: .isDirectory)
    }

    private func packageRowsURL() -> URL {
        rootDirectory.appending(path: "package-library.json")
    }
}
