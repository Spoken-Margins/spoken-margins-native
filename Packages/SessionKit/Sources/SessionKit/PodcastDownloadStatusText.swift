import Foundation

/// #936: the words for a podcast download that is running and one that has finished.
/// The item screen only said "Downloading" with a spinner, and the saved state was a bare
/// "Download Again" button, so a listener couldn't tell whether a tap had worked and tapped again.
public enum PodcastDownloadStatusText {
    /// The size in the unit a listener reads: "107 MB".
    public static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Downloading 42% of 107 MB", "Downloading…" until the size is known, and
    /// "Finishing the download…" once every byte has arrived but the file isn't saved yet.
    /// The percentage rounds down, so 100% is never shown before the file is ready.
    public static func downloading(
        _ record: PodcastDownloadRecord,
        byteString: (Int64) -> String = fileSize
    ) -> String {
        guard let progress = record.progress, let expected = record.expectedBytes else { return "Downloading…" }
        if progress >= 1 { return "Finishing the download…" }
        return "Downloading \(Int(progress * 100))% of \(byteString(expected))"
    }

    /// The short form for a button: "Downloading 42%", or "Downloading…" before the size is known.
    public static func buttonTitle(_ record: PodcastDownloadRecord) -> String {
        guard let progress = record.progress, progress < 1 else { return "Downloading…" }
        return "Downloading \(Int(progress * 100))%"
    }

    /// "Downloaded, 107 MB", or "Downloaded" when the size isn't known.
    public static func downloaded(
        _ record: PodcastDownloadRecord,
        byteString: (Int64) -> String = fileSize
    ) -> String {
        let bytes = record.bytesWritten > 0 ? record.bytesWritten : (record.expectedBytes ?? 0)
        return bytes > 0 ? "Downloaded, \(byteString(bytes))" : "Downloaded"
    }
}
