import Foundation

/// How the app learns how big a podcast episode is before it downloads it (#912), and what it does when
/// the host never says. The size is needed up front to reserve room in the offline storage budget.
///
/// A host that answers HEAD with 403 or 405, or with no length, still serves the audio on GET, so the
/// size comes from a one-byte ranged GET next. A host that announces nothing at all gets a modest
/// reservation, and the download is cut off at a hard bound: the audio is kept only if it then fits the
/// budget when it commits.
public enum PodcastDownloadSizeProbe {
    /// What to reserve for an episode whose host announces no size. An hour of 192 kbps audio is about
    /// 86 MB, so most episodes fit; a larger one is admitted by the ledger's commit-time overflow
    /// reservation instead. Kept small so one unannounced download neither evicts other episodes nor
    /// refuses a phone with little free space.
    public static let unannouncedReservationBytes: Int64 = 100_000_000

    /// The most an episode may write when its host announces no size at all, neither on HEAD, nor on the
    /// ranged GET, nor on the download itself. A three-hour episode at 320 kbps is about 430 MB, so this
    /// is generous for audio and still small enough that a stream with no end cannot fill the phone.
    public static let unannouncedLimitBytes: Int64 = 500_000_000

    public static let unannouncedLimitMessage =
        "This episode's host doesn't say how large it is, and it is larger than the 500 MB the app will save without knowing."

    /// What a one-byte ranged GET says about the size.
    public enum RangeProbe: Equatable, Sendable {
        /// The whole file's size.
        case length(Int64)
        /// The host answered but gave no size. The download goes ahead with a bounded reservation.
        case unannounced
        /// The host refused the request (404, 410, 403, 5xx ...). The download itself would be refused
        /// too, so the caller fails now, before it reserves any room that could evict other audio.
        case refused(statusCode: Int)
    }

    /// The size a HEAD response announces, or nil when the host refuses HEAD (anything but 2xx or 3xx) or
    /// leaves the length out or at zero. Nil means "ask with a ranged GET", never "fail".
    ///
    /// `expectedContentLength` is the URL loading system's figure and wins. `contentLengthHeader` is only
    /// a fallback for when that figure is unknown (-1) although the header was sent.
    public static func headLength(
        statusCode: Int,
        expectedContentLength: Int64,
        contentLengthHeader: String?
    ) -> Int64? {
        guard (200..<400).contains(statusCode) else { return nil }
        return wholeBodyLength(expectedContentLength: expectedContentLength, header: contentLengthHeader)
    }

    /// What the answer to a `Range: bytes=0-0` GET says about the whole file's size.
    ///
    /// - A 206 carries the total after the slash of `Content-Range` (`bytes 0-0/12345`).
    /// - A 200 means the host ignored the range, so its length is the whole file's.
    /// - A 416 (range not satisfiable) or any other 2xx or 3xx says nothing about the size, and the
    ///   download itself finds the real status.
    /// - Anything else (403, 404, 410, 5xx) is a refusal.
    public static func rangeProbe(
        statusCode: Int,
        contentRange: String?,
        expectedContentLength: Int64,
        contentLengthHeader: String?
    ) -> RangeProbe {
        switch statusCode {
        case 206:
            guard let contentRange, let total = contentRangeTotal(contentRange) else { return .unannounced }
            return .length(total)
        case 200:
            guard let length = wholeBodyLength(expectedContentLength: expectedContentLength, header: contentLengthHeader)
            else { return .unannounced }
            return .length(length)
        case 416, 201..<400:
            return .unannounced
        default:
            return .refused(statusCode: statusCode)
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
    /// modest reservation, never more than the budget could ever hold.
    public static func reservationBytes(announcedLength: Int64?, budgetLimitBytes: Int64) -> Int64 {
        if let announcedLength { return max(0, announcedLength) }
        return max(0, min(unannouncedReservationBytes, budgetLimitBytes))
    }

    /// True when a download whose size nobody announced has written more than the bound. "Announced" means
    /// the preflight recorded a size (`recordedExpectedBytes`) or the download itself reports a total. An
    /// announced size is held to the storage budget when the file commits instead (the ledger reserves the
    /// overrun or refuses it).
    public static func exceedsUnannouncedLimit(
        totalBytesWritten: Int64,
        recordedExpectedBytes: Int64?,
        totalBytesExpectedToWrite: Int64
    ) -> Bool {
        let announced = totalBytesExpectedToWrite > 0 || (recordedExpectedBytes ?? 0) > 0
        return !announced && totalBytesWritten > unannouncedLimitBytes
    }

    private static func wholeBodyLength(expectedContentLength: Int64, header: String?) -> Int64? {
        if expectedContentLength > 0 { return expectedContentLength }
        guard let header, let length = Int64(header.trimmingCharacters(in: .whitespaces)), length > 0 else { return nil }
        return length
    }
}
