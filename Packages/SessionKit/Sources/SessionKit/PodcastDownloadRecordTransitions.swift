import Foundation

/// How one podcast download row changes when its download starts, ends, fails or is evicted (#318). The coordinator
/// in the app used to build each new row inline, between its URLSession and SQLite calls, so the rules that keep a
/// working episode safe (a failed replacement never drops the saved audio; a finished download restates itself on
/// top of a row playback touched meanwhile) could only be checked through the app-hosted coordinator tests. These are
/// pure: they return the new row and touch no file, store or session. The caller stamps `updatedAt` when it saves.
extension PodcastDownloadRecord {
    /// The row when a download starts: its (secured) address, nothing written yet, no size and no old failure. A
    /// saved file named by `localRelativePath` stays, so a replacement download keeps the old episode playable.
    public func startingDownload(remoteURL: String) -> PodcastDownloadRecord {
        var record = self
        record.remoteURL = remoteURL
        record.state = .downloading
        record.bytesWritten = 0
        record.expectedBytes = nil
        record.failureReason = nil
        return record
    }

    /// The row once `fileName` (in `PodcastAudio/`) holds the finished download of `size` bytes.
    public func adoptingFile(named fileName: String, size: Int64) -> PodcastDownloadRecord {
        var record = self
        record.state = .availableOffline
        record.localRelativePath = fileName
        record.bytesWritten = size
        record.expectedBytes = size
        record.failureReason = nil
        return record
    }

    /// The row after its file was removed to free room: evicted, nothing kept, and no old failure.
    public func evicted() -> PodcastDownloadRecord {
        var record = self
        record.state = .evicted
        record.localRelativePath = nil
        record.bytesWritten = 0
        record.expectedBytes = nil
        record.failureReason = nil
        return record
    }

    /// The row after a download failed. `retainedFileSize` is the size of a saved file that is still on disk (nil when
    /// there is none): the failure then belongs to a replacement, so the saved audio stays available and the
    /// reason says so. With no saved file the row is `failed`.
    public func failing(reason: String, retainedFileSize: Int64?) -> PodcastDownloadRecord {
        var record = self
        if let retainedFileSize {
            record.state = .availableOffline
            record.bytesWritten = retainedFileSize
            record.expectedBytes = retainedFileSize
            record.failureReason = "Replacement download failed; saved audio is still available. \(reason)"
        } else {
            record.state = .failed
            record.failureReason = reason
        }
        return record
    }

    /// The text a row shows when its saved file turned out to be gone or cut short.
    public static let missingFileReason = "Downloaded file is missing or incomplete. Download it again."

    /// True when a saved file of `fileSize` bytes is the one this row recorded: not empty, and the same size as
    /// the bytes written when that was recorded (a row that recorded none accepts any non-empty file).
    public func acceptsSavedFile(ofSize fileSize: Int) -> Bool {
        fileSize > 0 && (bytesWritten == 0 || Int64(fileSize) == bytesWritten)
    }

    /// The row after its saved file was found missing or truncated: failed, with no file named.
    public func foundMissingFile() -> PodcastDownloadRecord {
        var record = self
        record.state = .failed
        record.localRelativePath = nil
        record.failureReason = Self.missingFileReason
        return record
    }

    /// What to do with a row whose download task ended with an error (not a finished transfer).
    public enum Interruption: Equatable, Sendable {
        /// The row waits: for Wi-Fi, or as streaming-only on cellular.
        case waiting(PodcastDownloadRecord)
        /// The download failed for `reason`.
        case failed(reason: String)
    }

    /// An error ended the download task. An unannounced episode that passed its size bound fails with that reason,
    /// since retrying on Wi-Fi would only write the same bytes again. A download the listener didn't start, off
    /// Wi-Fi, waits instead (`streamingOnly` on cellular). Anything else fails with the error's own text.
    public func interrupted(
        userInitiated: Bool,
        exceededUnannouncedLimit: Bool,
        transport: PodcastNetworkTransport,
        reason: String
    ) -> Interruption {
        if exceededUnannouncedLimit { return .failed(reason: PodcastDownloadSizeProbe.unannouncedLimitMessage) }
        if !userInitiated && transport != .wifi {
            var waiting = self
            waiting.state = transport == .cellular ? .streamingOnly : .waitingForWiFi
            waiting.failureReason = nil
            return .waiting(waiting)
        }
        return .failed(reason: reason)
    }

    // MARK: Launch and network changes

    /// What a launch makes of one stored row.
    public struct Restoration: Equatable, Sendable {
        /// The row to hold in memory.
        public var record: PodcastDownloadRecord
        /// Rows to write behind, in this order, because the stored row still says the old thing.
        public var writes: [PodcastDownloadRecord]
        /// True when the row's saved file is there and the app should be told its local asset is ready.
        public var localAssetReady: Bool
    }

    /// Repairs a stored row at launch. `retainedFileSize` and `fileExists` are asked only when the row needs them, so
    /// a launch makes no file check a row doesn't call for.
    /// - A row that failed while a saved file is still on disk was a failed replacement: the saved audio is available.
    /// - A row that says it is available but whose file is gone is `failed`, with no file named.
    /// - A row still `downloading` was cut off by the app ending: it waits for Wi-Fi.
    public func restoredAtLaunch(
        retainedFileSize: () -> Int64?,
        fileExists: () -> Bool
    ) -> Restoration {
        var record = self
        var writes: [PodcastDownloadRecord] = []
        if record.state == .failed, let size = retainedFileSize() {
            record.state = .availableOffline
            record.bytesWritten = size
            record.expectedBytes = size
            record.failureReason = "Replacement download failed; saved audio is still available."
            writes.append(record)
        }
        if record.state == .availableOffline {
            guard fileExists() else {
                record.state = .failed
                record.localRelativePath = nil
                record.failureReason = "Downloaded file is missing. Retry to download it again."
                writes.append(record)
                return Restoration(record: record, writes: writes, localAssetReady: false)
            }
            return Restoration(record: record, writes: writes, localAssetReady: true)
        }
        if record.state == .downloading {
            record.state = .waitingForWiFi
            writes.append(record)
        }
        return Restoration(record: record, writes: writes, localAssetReady: false)
    }

    /// What a row does when the network changes.
    public enum NetworkReaction: Equatable, Sendable {
        /// Start the download, not on the listener's behalf.
        case startAutomaticDownload
        /// Stop its automatic work and show this state.
        case pause(to: PodcastDownloadState)
    }

    /// On Wi-Fi, a row waiting for Wi-Fi or streaming only starts downloading. Off Wi-Fi, a row downloading or waiting
    /// stops, unless the listener asked for it: it becomes `streamingOnly` on cellular and `waitingForWiFi` otherwise.
    /// Every other row, and a listener's own download, is left alone.
    public func reaction(
        toTransport transport: PodcastNetworkTransport,
        userInitiated: Bool
    ) -> NetworkReaction? {
        if transport == .wifi {
            return state == .waitingForWiFi || state == .streamingOnly ? .startAutomaticDownload : nil
        }
        guard state == .downloading || state == .waitingForWiFi, !userInitiated else { return nil }
        return .pause(to: transport == .cellular ? .streamingOnly : .waitingForWiFi)
    }
}
