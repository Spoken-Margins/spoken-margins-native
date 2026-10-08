import Foundation

/// How the app learns how big a podcast episode is before it downloads it (#912), and what it does when
/// the host never says. The size is needed up front to reserve room in the offline storage budget.
///
/// A host that answers HEAD with 403 or 405, or with no length, still serves the audio on GET, so the
/// size comes from a one-byte ranged GET next. A host that announces nothing at all gets a bounded
/// reservation and a bounded download: the audio is kept only if it fits.
public enum PodcastDownloadSizeProbe {
    /// The most an episode may write when its host announces no size at all, neither on HEAD, nor on the
    /// ranged GET, nor on the download itself. A three-hour episode at 320 kbps is about 430 MB, so this
    /// is generous for audio and still small enough that a stream with no end cannot fill the phone.
    public static let unannouncedLimitBytes: Int64 = 500_000_000

    public static let unannouncedLimitMessage =
        "This episode's host doesn't say how large it is, and it is larger than the 500 MB the app will save without knowing."

    /// The size a HEAD response announces, or nil when the host refuses HEAD (anything but 2xx or 3xx) or
    /// leaves the length out or at zero. Nil means "ask with a ranged GET", never "fail".
    public static func headLength(statusCode: Int, expectedContentLength: Int64) -> Int64? {
        guard (200..<400).contains(statusCode), expectedContentLength > 0 else { return nil }
        return expectedContentLength
    }

    /// The whole file's size from the answer to a `Range: bytes=0-0` GET, or nil when it doesn't say.
    ///
    /// - A 206 carries the total after the slash of `Content-Range` (`bytes 0-0/12345`).
    /// - A 200 means the host ignored the range, so its `Content-Length` is the whole file.
    /// - Anything else (403, 404, 416, a 3xx that wasn't followed) says nothing about the size. The download
    ///   itself then finds the real status.
    public static func rangeProbeLength(statusCode: Int, contentRange: String?, expectedContentLength: Int64) -> Int64? {
        switch statusCode {
        case 206:
            guard let contentRange else { return nil }
            return contentRangeTotal(contentRange)
        case 200:
            return expectedContentLength > 0 ? expectedContentLength : nil
        default:
            return nil
        }
    }

    /// The total in `bytes <first>-<last>/<total>`, or nil for `*` (unknown total), a malformed header, a
    /// zero total, or a range that lies outside its total.
    public static func contentRangeTotal(_ header: String) -> Int64? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let spec = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard spec.count == 2,
              let total = Int64(spec[1].trimmingCharacters(in: .whitespaces)), total > 0 else { return nil }
        let bounds = spec[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let last = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              first >= 0, first <= last, last < total else { return nil }
        return total
    }

    /// How many bytes to reserve in the storage budget: the announced size, or for an unannounced one the
    /// bounded guess, never more than the budget could ever hold.
    public static func reservationBytes(announcedLength: Int64?, budgetLimitBytes: Int64) -> Int64 {
        if let announcedLength { return max(0, announcedLength) }
        return max(0, min(unannouncedLimitBytes, budgetLimitBytes))
    }

    /// True when a download whose host announces no total has written more than the bound. A download that
    /// announces its total is held to the storage budget when it commits instead (the ledger reserves the
    /// overrun or refuses it).
    public static func exceedsUnannouncedLimit(totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) -> Bool {
        totalBytesExpectedToWrite <= 0 && totalBytesWritten > unannouncedLimitBytes
    }
}
