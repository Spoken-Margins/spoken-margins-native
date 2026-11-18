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
        errorDescription: String
    ) -> Interruption {
        if exceededUnannouncedLimit { return .failed(reason: PodcastDownloadSizeProbe.unannouncedLimitMessage) }
        if !userInitiated && transport != .wifi {
            var waiting = self
            waiting.state = transport == .cellular ? .streamingOnly : .waitingForWiFi
            waiting.failureReason = nil
            return .waiting(waiting)
        }
        return .failed(reason: errorDescription)
    }
}
