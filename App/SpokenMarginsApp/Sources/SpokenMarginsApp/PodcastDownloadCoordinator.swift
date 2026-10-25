import Foundation
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
    private let ledger: OfflineStorageLedger
    private let directory: URL
    private let connectivity: any ConnectivityProviding
    private var connectivityObserver: UUID?
    private var isShutDown = false
    private let cacheLimit: PodcastCacheLimitGB
    private var activeItemId: String?
    private var activeTaskItemIds: Set<String> = []
    private var generations: [String: String] = [:]
    private var userInitiatedByItemId: [String: Bool] = [:]
    private(set) var preparationTasks: [String: Task<Void, Never>] = [:]
    private var attempts: [String: PodcastDownloadAttempt] = [:]
    private let contentLength: (@Sendable (URL, Bool) async throws -> Int64)?
    private let startDownload: ((URLRequest, String) -> Void)?
    /// Asks the host how large an episode is before it is downloaded (#912).
    private let preflightSession: URLSession
    /// Generations whose host never announced a size and then passed the bound; their cancellation is
    /// reported as that, not as a dropped connection.
    private var unannouncedLimitExceeded: Set<String> = []
    private var userInitiatedTaskIds: Set<Int> = []
    private var lastProgressPublishDateByItemId: [String: Date] = [:]
    /// Byte-progress ticks reach the screen at once but the database at most every few seconds (#2509).
    private var progressWriteGate = ProgressWriteGate()
    private var session: URLSession!

    init(
        store: SQLiteSessionStore,
        ledger: OfflineStorageLedger? = nil,
        applicationSupportDirectory: URL,
        cacheLimit: PodcastCacheLimitGB,
        monitorsNetwork: Bool = true,
        connectivity: (any ConnectivityProviding)? = nil,
        usesBackgroundSession: Bool = true,
        contentLength: (@Sendable (URL, Bool) async throws -> Int64)? = nil,
        startDownload: ((URLRequest, String) -> Void)? = nil,
        preflightSession: URLSession = .shared,
        foregroundSessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        self.store = store
        self.connectivity = connectivity ?? ConnectivityMonitor()
        self.contentLength = contentLength
        self.startDownload = startDownload
        self.preflightSession = preflightSession
        self.ledger = ledger ?? OfflineStorageLedger(
            repository: store,
            rootDirectory: applicationSupportDirectory
        )
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
            configuration = foregroundSessionConfiguration ?? .ephemeral
        }
        #else
        let configuration = foregroundSessionConfiguration ?? URLSessionConfiguration.default
        #endif
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        try restoreRecords()
        if monitorsNetwork {
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    for task in tasks {
                        if let attempt = PodcastDownloadAttempt.decode(task.taskDescription),
                           self.restoreAttempt(attempt) {
                            if attempt.userInitiated { self.userInitiatedTaskIds.insert(task.taskIdentifier) }
                        } else {
                            // Old unscoped tasks cannot safely publish into a replacement item.
                            task.cancel()
                            let owner = task.taskDescription.map { "podcast-download-\($0)" }
                            for reservation in (try? self.store.loadOfflineStorageReservations()) ?? []
                            where reservation.ownerId == owner {
                                try? self.store.deleteOfflineStorageReservation(id: reservation.id)
                            }
                        }
                    }
                    self.startNetworkMonitor()
                }
            }
        }
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func shutdown() {
        // The monitor is shared and outlives this coordinator; only stop listening to it. A cancelled
        // private monitor used to make a late start a no-op; isShutDown does that now.
        isShutDown = true
        if let connectivityObserver { connectivity.removeObserver(connectivityObserver) }
        connectivityObserver = nil
        session.invalidateAndCancel()
        for itemId in Array(generations.keys) { invalidateAttempt(itemId: itemId) }
    }

    private func invalidateAttempt(itemId: String) {
        let generation = generations.removeValue(forKey: itemId)
        if let generation { unannouncedLimitExceeded.remove(generation) }
        userInitiatedByItemId[itemId] = nil
        preparationTasks.removeValue(forKey: itemId)?.cancel()
        activeTaskItemIds.remove(itemId)
        lastProgressPublishDateByItemId[itemId] = nil
        progressWriteGate.forget(key: itemId)
        if let attempt = attempts.removeValue(forKey: itemId) {
            try? store.deleteOfflineStorageReservation(id: attempt.reservationId)
        }
        session.getAllTasks { tasks in
            for task in tasks {
                let attempt = PodcastDownloadAttempt.decode(task.taskDescription)
                if (attempt?.itemId == itemId && attempt?.generation == generation)
                    || task.taskDescription == itemId { task.cancel() }
            }
        }
    }

    /// Used both during URLSession reconstruction and by early delegate callbacks.
    @discardableResult
    func restoreAttempt(_ attempt: PodcastDownloadAttempt) -> Bool {
        if let current = generations[attempt.itemId] { return current == attempt.generation }
        guard var record = recordsByItemId[attempt.itemId],
              record.state == .downloading || record.state == .waitingForWiFi,
              let reservation = try? store.loadOfflineStorageReservations().first(where: { $0.id == attempt.reservationId }),
              reservation.ownerId == "podcast-download-\(attempt.itemId):\(attempt.generation)",
              reservation.expiresAt > Date() else { return false }
        generations[attempt.itemId] = attempt.generation
        attempts[attempt.itemId] = attempt
        userInitiatedByItemId[attempt.itemId] = attempt.userInitiated
        activeTaskItemIds.insert(attempt.itemId)
        record.state = .downloading
        persist(record)
        return true
    }

    private func owns(_ attempt: PodcastDownloadAttempt) -> Bool {
        generations[attempt.itemId] == attempt.generation && recordsByItemId[attempt.itemId] != nil
    }

    func status(itemId: String) -> PodcastDownloadState? { recordsByItemId[itemId]?.state }

    func validatedLocalURL(for itemId: String) -> URL? {
        guard var record = recordsByItemId[itemId] else { return nil }
        if record.state == .downloading {
            // A replacement download keeps the previously saved episode playable until it
            // completes. A first download has no saved file yet and must not be marked failed.
            return retainedLocalFile(for: record)?.url
        }
        guard record.state == .availableOffline else { return nil }
        if let url = localURL(for: record),
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0, record.bytesWritten == 0 || Int64(size) == record.bytesWritten { return url }
        record.state = .failed
        record.localRelativePath = nil
        record.failureReason = "Downloaded file is missing or incomplete. Download it again."
        persist(record)
        return nil
    }

    func configureActiveItem(_ itemId: String?) {
        activeItemId = itemId
        // The shared ledger can evict independently of the podcast cache.
        // Keep protection for the whole listening session, including Margins
        // and paused playback, and transfer it only when the active item changes.
        let activePath = itemId.flatMap { recordsByItemId[$0]?.localRelativePath }
            .map { "PodcastAudio/\($0)" }
        for asset in (try? store.loadOwnedOfflineAssets()) ?? [] where asset.category == .podcast {
            let isActive = itemId != nil && (asset.itemId == itemId
                || (activePath != nil && asset.relativePath == activePath))
            let wasActive = asset.protections.contains(.activePlayback)
            guard isActive != wasActive else { continue }
            // One atomic row update, so a ledger reconcile can't write back a copy without it (#287).
            _ = try? store.updateOwnedOfflineAsset(id: asset.id) { current in
                if isActive { current.protections.insert(.activePlayback) }
                else { current.protections.remove(.activePlayback) }
            }
        }
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

        guard let transportURL = PodcastDownloadTransportURLPolicy.secureURL(for: remoteURL) else {
            var record = existing ?? PodcastDownloadRecord(
                id: "podcast-download-\(itemId)",
                itemId: itemId,
                remoteURL: remoteURL.absoluteString,
                state: .failed
            )
            record.remoteURL = remoteURL.absoluteString
            fail(record, reason: "The podcast audio URL does not support a secure HTTP connection.")
            return
        }

        let remoteAsset = AudioAsset(
            id: "podcast-remote-\(itemId)",
            itemId: itemId,
            audioSourceType: .remoteStream,
            availability: .remote,
            url: transportURL.absoluteString
        )
        try? store.saveAudioAsset(remoteAsset)

        var record = existing ?? PodcastDownloadRecord(
            id: "podcast-download-\(itemId)",
            itemId: itemId,
            remoteURL: transportURL.absoluteString,
            state: .streamingOnly
        )
        record.remoteURL = transportURL.absoluteString
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

    func redownload(itemId: String) {
        guard var record = recordsByItemId[itemId] else { return }
        // A copy is already coming down. Another tap would cancel it and start again from 0 bytes (#936).
        if record.state == .downloading, activeTaskItemIds.contains(itemId) { return }
        invalidateAttempt(itemId: itemId)
        record.retryCount += 1
        record.failureReason = nil
        beginDownload(record: record, userInitiated: true)
    }

    func retry(itemId: String) {
        guard var record = recordsByItemId[itemId], let url = URL(string: record.remoteURL) else { return }
        record.retryCount += 1
        persist(record)
        register(itemId: itemId, remoteURL: url, userInitiated: true)
    }

    @discardableResult
    func downloadNow(itemId: String) -> Bool {
        guard networkTransport != .unavailable,
              let record = recordsByItemId[itemId],
              let url = URL(string: record.remoteURL) else { return false }
        register(itemId: itemId, remoteURL: url, userInitiated: true)
        return recordsByItemId[itemId]?.state == .downloading
            || recordsByItemId[itemId]?.state == .availableOffline
    }

    func clearDownloads() {
        for record in Array(recordsByItemId.values)
            where record.state == .availableOffline && record.itemId != activeItemId {
            evict(record)
        }
    }

    func removeItem(_ itemId: String) {
        invalidateAttempt(itemId: itemId)
        if let record = recordsByItemId[itemId], let localURL = localURL(for: record) {
            try? FileManager.default.removeItem(at: localURL)
        }
        recordsByItemId[itemId] = nil
        try? store.deleteAudioAsset(id: "podcast-local-\(itemId)")
        try? store.deleteAudioAsset(id: "podcast-remote-\(itemId)")
        try? store.deleteOwnedOfflineAsset(id: "podcast-offline-\(itemId)")
        if let id = try? store.loadPodcastDownload(itemId: itemId)?.id {
            try? store.deletePodcastDownload(id: id)
        }
    }

    func setNetworkTransportForTesting(_ transport: PodcastNetworkTransport) {
        networkChanged(to: transport)
    }

    private func restoreRecords() throws {
        for var record in try store.loadPodcastDownloads() {
            if record.state == .failed, let retained = retainedLocalFile(for: record) {
                record.state = .availableOffline
                record.bytesWritten = retained.size
                record.expectedBytes = retained.size
                record.failureReason = "Replacement download failed; saved audio is still available."
                try store.savePodcastDownload(record)
            }
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
            // Invalidate preparation as well as URLSession work. A delayed HEAD
            // response must not start an automatic download after leaving Wi-Fi.
            for var record in Array(recordsByItemId.values)
            where record.state == .downloading || record.state == .waitingForWiFi {
                guard userInitiatedByItemId[record.itemId] != true else { continue }
                invalidateAttempt(itemId: record.itemId)
                record.state = transport == .cellular ? .streamingOnly : .waitingForWiFi
                persist(record)
            }
        }
    }

    private func startNetworkMonitor() {
        guard !isShutDown, connectivityObserver == nil else { return }
        connectivityObserver = connectivity.addObserver { [weak self] transport in
            self?.networkChanged(to: transport)
        }
        connectivity.start()
    }

    private func beginDownload(record: PodcastDownloadRecord, userInitiated: Bool) {
        guard !activeTaskItemIds.contains(record.itemId) else { return }
        guard let originalURL = URL(string: record.remoteURL),
              let url = PodcastDownloadTransportURLPolicy.secureURL(for: originalURL) else {
            fail(record, reason: "The podcast audio URL is invalid.")
            return
        }
        activeTaskItemIds.insert(record.itemId)
        let generation = UUID().uuidString
        generations[record.itemId] = generation
        userInitiatedByItemId[record.itemId] = userInitiated
        var updated = record
        updated.remoteURL = url.absoluteString
        updated.state = .downloading
        updated.bytesWritten = 0
        updated.expectedBytes = nil
        updated.failureReason = nil
        persist(updated)
        preparationTasks[record.itemId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generations[record.itemId] == generation { self.preparationTasks[record.itemId] = nil }
            }
            do {
                let announced = try await self.announcedContentLength(at: url, userInitiated: userInitiated)
                guard self.generations[record.itemId] == generation else { return }
                var budgetLimitBytes: Int64 = 0
                if announced == nil { budgetLimitBytes = try self.store.loadOfflineStorageBudget().limitBytes }
                let reservation = try await self.ledger.reserve(
                    ownerId: "podcast-download-\(record.itemId):\(generation)",
                    byteCount: PodcastDownloadSizeProbe.reservationBytes(
                        announcedLength: announced,
                        budgetLimitBytes: budgetLimitBytes
                    ),
                    lifetime: 24 * 60 * 60
                )
                guard self.generations[record.itemId] == generation else {
                    try? await self.ledger.release(reservationId: reservation.id)
                    return
                }
                let attempt = PodcastDownloadAttempt(itemId: record.itemId, generation: generation,
                                                      reservationId: reservation.id, userInitiated: userInitiated)
                self.attempts[record.itemId] = attempt
                var request = URLRequest(url: url)
                request.allowsCellularAccess = userInitiated
                request.allowsExpensiveNetworkAccess = userInitiated
                request.allowsConstrainedNetworkAccess = userInitiated
                var reserved = updated
                reserved.expectedBytes = announced
                self.persist(reserved)
                if let startDownload = self.startDownload {
                    startDownload(request, attempt.taskDescription)
                } else {
                    let task = self.session.downloadTask(with: request)
                    task.taskDescription = attempt.taskDescription
                    if userInitiated { self.userInitiatedTaskIds.insert(task.taskIdentifier) }
                    task.resume()
                }
            } catch {
                guard self.generations[record.itemId] == generation else { return }
                self.invalidateAttempt(itemId: record.itemId)
                self.fail(updated, reason: error.localizedDescription)
            }
        }
    }

    /// The episode's size when its host says, asked with HEAD and then with a one-byte ranged GET; nil when
    /// the host says nothing. A host that refuses HEAD or leaves out the length still serves the audio, so
    /// neither is a failure (#912): a nil size reserves a bounded amount and the download is held to it.
    private func announcedContentLength(at url: URL, userInitiated: Bool) async throws -> Int64? {
        if let contentLength { return try await contentLength(url, userInitiated) }
        var head = URLRequest(url: url)
        head.timeoutInterval = 30
        head.httpMethod = "HEAD"
        head.allowsCellularAccess = userInitiated
        do {
            let (_, response) = try await preflightSession.data(for: head)
            if let http = response as? HTTPURLResponse,
               let length = PodcastDownloadSizeProbe.headLength(
                   statusCode: http.statusCode,
                   expectedContentLength: http.expectedContentLength,
                   contentLengthHeader: http.value(forHTTPHeaderField: "Content-Length")
               ) {
                return length
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            // Some hosts drop the connection on HEAD. The ranged GET below asks again and reports its own error.
        }
        var probe = URLRequest(url: url)
        probe.timeoutInterval = 30
        probe.allowsCellularAccess = userInitiated
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (stream, response) = try await preflightSession.bytes(for: probe)
        // Only the headers are wanted. A host that ignores the range must not send the whole episode to be measured.
        stream.task.cancel()
        guard let http = response as? HTTPURLResponse else { return nil }
        switch PodcastDownloadSizeProbe.rangeProbe(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            expectedContentLength: http.expectedContentLength,
            contentLengthHeader: http.value(forHTTPHeaderField: "Content-Length")
        ) {
        case .length(let length): return length
        case .unannounced: return nil
        // Fail before reserving: a reservation can evict other episodes, and this download can't succeed.
        case .refused(let statusCode): throw PodcastDownloadFailure.hostRefused(statusCode: statusCode)
        }
    }

    private func persist(_ record: PodcastDownloadRecord) {
        var updated = record
        updated.updatedAt = Date()
        recordsByItemId[updated.itemId] = updated
        try? store.savePodcastDownload(updated)
        progressWriteGate.didWrite(key: updated.itemId, at: updated.updatedAt)
        onRecordChanged?(updated)
    }

    /// A byte-progress tick: the screen sees it now, the row is written at most every `progressWriteGate.interval`
    /// seconds, so a download does not put a SQLite write on the main actor twice a second (#2509). The
    /// finishing tick writes at once. Stale bytes in a row are harmless after a kill: a `downloading` row
    /// is reset to `waitingForWiFi` on restore and the next progress callback restates the bytes.
    private func persistProgress(_ record: PodcastDownloadRecord, finishing: Bool) {
        var updated = record
        updated.updatedAt = Date()
        recordsByItemId[updated.itemId] = updated
        if finishing || progressWriteGate.shouldWrite(key: updated.itemId, at: updated.updatedAt) {
            try? store.savePodcastDownload(updated)
            progressWriteGate.didWrite(key: updated.itemId, at: updated.updatedAt)
        }
        onRecordChanged?(updated)
    }

    private func fail(_ record: PodcastDownloadRecord, reason: String) {
        var updated = record
        if let retained = retainedLocalFile(for: record) {
            updated.state = .availableOffline
            updated.bytesWritten = retained.size
            updated.expectedBytes = retained.size
            updated.failureReason = "Replacement download failed; saved audio is still available. \(reason)"
        } else {
            updated.state = .failed
            updated.failureReason = reason
        }
        persist(updated)
    }

    private func retainedLocalFile(for record: PodcastDownloadRecord) -> (url: URL, size: Int64)? {
        guard let url = localURL(for: record),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil }
        return (url, Int64(size))
    }

    private func localURL(for record: PodcastDownloadRecord?) -> URL? {
        guard let path = record?.localRelativePath else { return nil }
        return directory.appending(path: path)
    }

    private func evict(_ record: PodcastDownloadRecord) {
        if let url = localURL(for: record) { try? FileManager.default.removeItem(at: url) }
        try? store.deleteAudioAsset(id: "podcast-local-\(record.itemId)")
        try? store.deleteOwnedOfflineAsset(id: "podcast-offline-\(record.itemId)")
        var updated = record
        updated.state = .evicted
        updated.localRelativePath = nil
        updated.bytesWritten = 0
        updated.expectedBytes = nil
        updated.failureReason = nil
        persist(updated)
    }

    /// Adopts only the current attempt. Staging filenames are unique, so a late
    /// callback never removes or overwrites a newer rendition's file.
    func finishDownload(_ attempt: PodcastDownloadAttempt, stagedURL: URL?, responseOK: Bool) async {
        defer { if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) } }
        guard owns(attempt) || restoreAttempt(attempt) else {
            try? await ledger.release(reservationId: attempt.reservationId)
            return
        }
        guard var record = recordsByItemId[attempt.itemId] else { return }
        do {
            guard responseOK, let stagedURL,
                  let size = try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // A 200 can carry a sign-in page or an error message. Neither may replace a working episode (#919).
            guard !DownloadedAudioSniffer.looksLikeText(fileAt: stagedURL) else {
                throw PodcastDownloadFailure.notAudio
            }
            let destination = directory.appending(path: "\(attempt.generation).\(stagedURL.pathExtension)")
            try FileManager.default.moveItem(at: stagedURL, to: destination)
            do {
                // Playback can start while the commit waits on the ledger, so the row is committed
                // protected and the protection is settled once this actor resumes (#541). Other
                // ledgers on this store can't evict the new file in between.
                try await ledger.commit(reservationId: attempt.reservationId, asset: OwnedOfflineAsset(
                    id: "podcast-offline-\(attempt.itemId)", itemId: attempt.itemId, category: .podcast,
                    relativePath: "PodcastAudio/\(destination.lastPathComponent)", byteCount: Int64(size),
                    isReproducible: true, protections: [.activePlayback]))
                guard owns(attempt) else {
                    removeAdoptedFile(destination, itemId: attempt.itemId)
                    return
                }
                let isActive = activeItemId == attempt.itemId
                guard try store.updateOwnedOfflineAsset(id: "podcast-offline-\(attempt.itemId)", { current in
                    if isActive { current.protections.insert(.activePlayback) }
                    else { current.protections.remove(.activePlayback) }
                }) != nil else {
                    // Evicted or reconciled away already: don't publish a file that may be gone.
                    throw CocoaError(.fileNoSuchFile)
                }
                // Save the asset before publishing availability.
                try store.saveAudioAsset(AudioAsset(id: "podcast-local-\(attempt.itemId)", itemId: attempt.itemId,
                    audioSourceType: .nativeMediaFile, availability: .localPhone, filePath: destination.lastPathComponent))
                let previousFile = localURL(for: record)
                record.state = .availableOffline
                record.localRelativePath = destination.lastPathComponent
                record.bytesWritten = Int64(size)
                record.expectedBytes = Int64(size)
                record.failureReason = nil
                record.updatedAt = Date()
                try store.savePodcastDownload(record)
                recordsByItemId[record.itemId] = record
                onRecordChanged?(record)
                invalidateAttempt(itemId: attempt.itemId)
                if let previousFile, previousFile != destination { try? FileManager.default.removeItem(at: previousFile) }
                onLocalAssetReady?(attempt.itemId, destination)
            } catch {
                removeAdoptedFile(destination, itemId: attempt.itemId)
                throw error
            }
        } catch {
            guard owns(attempt) else { return }
            invalidateAttempt(itemId: attempt.itemId)
            fail(record, reason: error.localizedDescription)
        }
    }

    private func removeAdoptedFile(_ url: URL, itemId: String) {
        try? FileManager.default.removeItem(at: url)
        if let asset = try? store.loadOwnedOfflineAssets().first(where: { $0.id == "podcast-offline-\(itemId)" }),
           asset.relativePath == "PodcastAudio/\(url.lastPathComponent)" {
            try? store.deleteOwnedOfflineAsset(id: asset.id)
        }
    }

    func completeDownload(_ attempt: PodcastDownloadAttempt, error: Error?) {
        // A successful URLSession completion may precede async file adoption.
        guard let error, owns(attempt) || restoreAttempt(attempt),
              let record = recordsByItemId[attempt.itemId] else { return }
        let exceededUnannouncedLimit = unannouncedLimitExceeded.contains(attempt.generation)
        invalidateAttempt(itemId: attempt.itemId)
        if exceededUnannouncedLimit {
            // Not a dropped connection: retrying on Wi-Fi would only write the same bytes again.
            fail(record, reason: PodcastDownloadSizeProbe.unannouncedLimitMessage)
        } else if !attempt.userInitiated && networkTransport != .wifi {
            var waiting = record
            waiting.state = networkTransport == .cellular ? .streamingOnly : .waitingForWiFi
            waiting.failureReason = nil
            persist(waiting)
        } else {
            fail(record, reason: error.localizedDescription)
        }
    }
}

extension PodcastDownloadCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard let attempt = PodcastDownloadAttempt.decode(downloadTask.taskDescription) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.owns(attempt) || self.restoreAttempt(attempt),
                  var record = self.recordsByItemId[attempt.itemId] else { return }
            if PodcastDownloadSizeProbe.exceedsUnannouncedLimit(
                totalBytesWritten: totalBytesWritten,
                recordedExpectedBytes: record.expectedBytes,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            ) {
                // The host never said how large this is and it has passed the bound: stop writing (#912).
                self.unannouncedLimitExceeded.insert(attempt.generation)
                downloadTask.cancel()
                return
            }
            let now = Date()
            let complete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
            if !complete, let last = self.lastProgressPublishDateByItemId[attempt.itemId], now.timeIntervalSince(last) < 0.5 { return }
            self.lastProgressPublishDateByItemId[attempt.itemId] = now
            record.bytesWritten = totalBytesWritten
            // A chunked download keeps the size the preflight recorded, so it is still known to be announced (#912).
            record.expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : record.expectedBytes
            self.persistProgress(record, finishing: complete)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        guard let attempt = PodcastDownloadAttempt.decode(downloadTask.taskDescription) else { return }
        let responseOK = (downloadTask.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        // The URLSession temporary file is only valid until this delegate returns.
        let ext = URL(fileURLWithPath: downloadTask.response?.suggestedFilename ?? "episode.audio").pathExtension
        let safeExtension = !ext.isEmpty && ext.count <= 10 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "audio"
        let staged = directory.appending(path: "staging-\(UUID().uuidString).\(safeExtension)")
        let preserved: URL?
        do { try FileManager.default.moveItem(at: location, to: staged); preserved = staged }
        catch { preserved = nil }
        Task { @MainActor [weak self] in
            guard let self else { if let preserved { try? FileManager.default.removeItem(at: preserved) }; return }
            await self.finishDownload(attempt, stagedURL: preserved, responseOK: responseOK)
        }
    }
}

extension PodcastDownloadCoordinator: URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              let secureURL = PodcastDownloadTransportURLPolicy.secureURL(for: url) else {
            completionHandler(request)
            return
        }
        var secureRequest = request
        secureRequest.url = secureURL
        completionHandler(secureRequest)
    }

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
        guard let attempt = PodcastDownloadAttempt.decode(task.taskDescription) else { return }
        Task { @MainActor [weak self] in
            self?.userInitiatedTaskIds.remove(task.taskIdentifier)
            self?.completeDownload(attempt, error: error)
        }
    }
}
