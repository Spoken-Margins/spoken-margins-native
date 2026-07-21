import Foundation
import Network
import SessionKit
import SessionKitPersistence

@MainActor
final class PodcastDownloadCoordinator: NSObject, ObservableObject, @unchecked Sendable {
    static let backgroundSessionIdentifier = "com.spokenmargins.podcast-downloads"
    @Published private(set) var recordsByItemId: [String: PodcastDownloadRecord] = [:]
    @Published private(set) var networkTransport: PodcastNetworkTransport = .other

    var onRecordChanged: ((PodcastDownloadRecord) -> Void)?
    var onLocalAssetReady: ((String, URL) -> Void)?

    private let store: SQLiteSessionStore
    private let directory: URL
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.spokenmargins.podcast-network")
    private var cacheLimit: PodcastCacheLimitGB
    private var activeItemId: String?
    private var activeTaskItemIds: Set<String> = []
    private var userInitiatedTaskIds: Set<Int> = []
    private var session: URLSession!

    init(
        store: SQLiteSessionStore,
        applicationSupportDirectory: URL,
        cacheLimit: PodcastCacheLimitGB,
        monitorsNetwork: Bool = true,
        usesBackgroundSession: Bool = true
    ) throws {
        self.store = store
        self.cacheLimit = cacheLimit
        directory = applicationSupportDirectory.appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        super.init()

        #if os(iOS)
        let configuration: URLSessionConfiguration
        if usesBackgroundSession {
            configuration = URLSessionConfiguration.background(
                withIdentifier: Self.backgroundSessionIdentifier
            )
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
        } else {
            configuration = .ephemeral
        }
        #else
        let configuration = URLSessionConfiguration.default
        #endif
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try restoreRecords()
        if monitorsNetwork {
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    for task in tasks {
                        guard let itemId = task.taskDescription else { continue }
                        self.activeTaskItemIds.insert(itemId)
                        if var record = self.recordsByItemId[itemId] {
                            record.state = .downloading
                            self.persist(record)
                        }
                    }
                    self.startNetworkMonitor()
                }
            }
        }
    }

    deinit {
        monitor.cancel()
        session?.invalidateAndCancel()
    }

    func shutdown() {
        monitor.cancel()
        session.invalidateAndCancel()
    }

    func status(itemId: String) -> PodcastDownloadState? { recordsByItemId[itemId]?.state }

    func configureActiveItem(_ itemId: String?) {
        activeItemId = itemId
        guard let itemId, var record = recordsByItemId[itemId] else { return }
        record.lastPlayedAt = Date()
        record.updatedAt = Date()
        persist(record)
    }

    func register(itemId: String, remoteURL: URL, userInitiated: Bool = false) {
        let existing = recordsByItemId[itemId]
        if existing?.state == .availableOffline,
           let localURL = localURL(for: existing),
           FileManager.default.fileExists(atPath: localURL.path) {
            onLocalAssetReady?(itemId, localURL)
            return
        }
        if existing?.state == .downloading { return }

        let remoteAsset = AudioAsset(
            id: "podcast-remote-\(itemId)",
            itemId: itemId,
            audioSourceType: .remoteStream,
            availability: .remote,
            url: remoteURL.absoluteString
        )
        try? store.saveAudioAsset(remoteAsset)

        var record = existing ?? PodcastDownloadRecord(
            id: "podcast-download-\(itemId)",
            itemId: itemId,
            remoteURL: remoteURL.absoluteString,
            state: .streamingOnly
        )
        record.remoteURL = remoteURL.absoluteString
        record.failureReason = nil
        switch PodcastDownloadPolicy.action(for: networkTransport, userInitiated: userInitiated) {
        case .download:
            beginDownload(record: record, userInitiated: userInitiated)
        case .waitForWiFi:
            record.state = .waitingForWiFi
            persist(record)
        case .streamOnly:
            record.state = .streamingOnly
            persist(record)
        }
    }

    func retry(itemId: String) {
        guard var record = recordsByItemId[itemId], let url = URL(string: record.remoteURL) else { return }
        record.retryCount += 1
        persist(record)
        register(itemId: itemId, remoteURL: url, userInitiated: true)
    }

    func setCacheLimit(_ limit: PodcastCacheLimitGB) {
        cacheLimit = limit
        enforceCacheLimit()
    }

    func clearDownloads() {
        for record in Array(recordsByItemId.values)
            where record.state == .availableOffline && record.itemId != activeItemId {
            evict(record)
        }
    }

    func removeItem(_ itemId: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == itemId }.forEach { $0.cancel() }
        }
        if let record = recordsByItemId[itemId], let localURL = localURL(for: record) {
            try? FileManager.default.removeItem(at: localURL)
        }
        recordsByItemId[itemId] = nil
        try? store.deleteAudioAsset(id: "podcast-local-\(itemId)")
        try? store.deleteAudioAsset(id: "podcast-remote-\(itemId)")
        if let id = try? store.loadPodcastDownload(itemId: itemId)?.id {
            try? store.deletePodcastDownload(id: id)
        }
    }

    func setNetworkTransportForTesting(_ transport: PodcastNetworkTransport) {
        networkChanged(to: transport)
    }

    private func restoreRecords() throws {
        for var record in try store.loadPodcastDownloads() {
            if record.state == .availableOffline {
                guard let url = localURL(for: record), FileManager.default.fileExists(atPath: url.path) else {
                    record.state = .failed
                    record.localRelativePath = nil
                    record.failureReason = "Downloaded file is missing. Retry to download it again."
                    try store.savePodcastDownload(record)
                    recordsByItemId[record.itemId] = record
                    continue
                }
                onLocalAssetReady?(record.itemId, url)
            } else if record.state == .downloading {
                record.state = .waitingForWiFi
                try store.savePodcastDownload(record)
            }
            recordsByItemId[record.itemId] = record
        }
    }

    private func networkChanged(to transport: PodcastNetworkTransport) {
        networkTransport = transport
        if transport == .wifi {
            let waiting = recordsByItemId.values.filter {
                $0.state == .waitingForWiFi || $0.state == .streamingOnly
            }
            for record in waiting { beginDownload(record: record, userInitiated: false) }
        } else {
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    for task in tasks where !self.userInitiatedTaskIds.contains(task.taskIdentifier) {
                        task.cancel()
                    }
                }
            }
            for var record in recordsByItemId.values where record.state == .downloading || record.state == .waitingForWiFi {
                record.state = transport == .cellular ? .streamingOnly : .waitingForWiFi
                persist(record)
            }
        }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let transport: PodcastNetworkTransport
            if path.status != .satisfied {
                transport = .unavailable
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                transport = .wifi
            } else if path.usesInterfaceType(.cellular) {
                transport = .cellular
            } else {
                transport = .other
            }
            Task { @MainActor [weak self] in self?.networkChanged(to: transport) }
        }
        monitor.start(queue: monitorQueue)
    }

    private func beginDownload(record: PodcastDownloadRecord, userInitiated: Bool) {
        guard !activeTaskItemIds.contains(record.itemId) else { return }
        guard let url = URL(string: record.remoteURL) else {
            fail(record, reason: "The podcast audio URL is invalid.")
            return
        }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = userInitiated
        if #available(iOS 13.0, macOS 10.15, *) {
            request.allowsExpensiveNetworkAccess = userInitiated
            request.allowsConstrainedNetworkAccess = userInitiated
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = record.itemId
        activeTaskItemIds.insert(record.itemId)
        if userInitiated { userInitiatedTaskIds.insert(task.taskIdentifier) }
        var updated = record
        updated.state = .downloading
        updated.bytesWritten = 0
        updated.expectedBytes = nil
        updated.failureReason = nil
        persist(updated)
        task.resume()
    }

    private func persist(_ record: PodcastDownloadRecord) {
        var updated = record
        updated.updatedAt = Date()
        recordsByItemId[updated.itemId] = updated
        try? store.savePodcastDownload(updated)
        onRecordChanged?(updated)
    }

    private func fail(_ record: PodcastDownloadRecord, reason: String) {
        var updated = record
        updated.state = .failed
        updated.failureReason = reason
        persist(updated)
    }

    private func localURL(for record: PodcastDownloadRecord?) -> URL? {
        guard let path = record?.localRelativePath else { return nil }
        return directory.appending(path: path)
    }

    private func enforceCacheLimit() {
        let protected = Set([activeItemId].compactMap { $0 })
            .union(recordsByItemId.values.filter { $0.state == .downloading }.map(\.itemId))
        let evictions = PodcastCacheEvictionPlanner.recordsToEvict(
            from: Array(recordsByItemId.values),
            limitBytes: cacheLimit.bytes,
            protectedItemIds: protected
        )
        evictions.forEach(evict)
    }

    private func evict(_ record: PodcastDownloadRecord) {
        if let url = localURL(for: record) { try? FileManager.default.removeItem(at: url) }
        try? store.deleteAudioAsset(id: "podcast-local-\(record.itemId)")
        var updated = record
        updated.state = .evicted
        updated.localRelativePath = nil
        updated.bytesWritten = 0
        updated.expectedBytes = nil
        updated.failureReason = nil
        persist(updated)
    }

    nonisolated private func destinationURL(for task: URLSessionDownloadTask) -> URL? {
        guard let itemId = task.taskDescription else { return nil }
        let suggested = task.response?.suggestedFilename ?? task.originalRequest?.url?.lastPathComponent ?? "episode.m4a"
        let ext = URL(fileURLWithPath: suggested).pathExtension
        let filename = ext.isEmpty ? "\(itemId).audio" : "\(itemId).\(ext)"
        return directory.appending(path: filename)
    }
}

extension PodcastDownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let itemId = downloadTask.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self, var record = self.recordsByItemId[itemId] else { return }
            record.bytesWritten = totalBytesWritten
            record.expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            self.persist(record)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let itemId = downloadTask.taskDescription,
              let destination = destinationURL(for: downloadTask),
              let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            Task { @MainActor [weak self] in
                guard let self, let itemId = downloadTask.taskDescription,
                      let record = self.recordsByItemId[itemId] else { return }
                self.fail(record, reason: "The podcast server did not return a complete audio file.")
            }
            return
        }
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDestination = destination
            try mutableDestination.setResourceValues(resourceValues)
            Task { @MainActor [weak self] in
                guard let self, var record = self.recordsByItemId[itemId] else { return }
                record.state = .availableOffline
                record.localRelativePath = destination.lastPathComponent
                record.bytesWritten = Int64(fileSize)
                record.expectedBytes = Int64(fileSize)
                record.failureReason = nil
                self.persist(record)
                let asset = AudioAsset(
                    id: "podcast-local-\(itemId)",
                    itemId: itemId,
                    audioSourceType: .nativeMediaFile,
                    availability: .localPhone,
                    filePath: destination.lastPathComponent
                )
                try? self.store.saveAudioAsset(asset)
                self.onLocalAssetReady?(itemId, destination)
                self.enforceCacheLimit()
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self, let record = self.recordsByItemId[itemId] else { return }
                self.fail(record, reason: "Downloaded audio was corrupt or could not be saved.")
            }
        }
    }
}

extension PodcastDownloadCoordinator: URLSessionTaskDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            PodcastBackgroundSessionEvents.completeIfPending()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let itemId = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeTaskItemIds.remove(itemId)
            defer { self.userInitiatedTaskIds.remove(task.taskIdentifier) }
            guard let error else { return }
            if let record = self.recordsByItemId[itemId],
               record.state != .downloading,
               self.networkTransport == .wifi,
               record.state == .waitingForWiFi || record.state == .streamingOnly {
                self.beginDownload(record: record, userInitiated: false)
                return
            }
            guard let record = self.recordsByItemId[itemId], record.state == .downloading else { return }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if self.networkTransport != .wifi, !self.userInitiatedTaskIds.contains(task.taskIdentifier) {
                var waiting = record
                waiting.state = self.networkTransport == .cellular ? .streamingOnly : .waitingForWiFi
                waiting.failureReason = nil
                self.persist(waiting)
            } else {
                self.fail(record, reason: error.localizedDescription)
            }
        }
    }
}
