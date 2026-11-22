import Foundation

/// What the sheet says when opening a friend's share link or `.spokenmargins` file fails (#3801).
///
/// One row per failure, in the words of the share page (the web's words, with the app's "tap Try Again"). The headline
/// says what was tapped failed ("This link…", "This file…"), so the message is tied to the tap even over a Library a
/// new friend has never seen, and each row names exactly one next step: in its line, or as its Try Again button.
/// Colour never carries the meaning; the sheet's warning icon sits above these words.
///
/// This is only the words and the buttons; the sheet that shows them is `PacketOpenFailureSheet` in the app.
public struct PacketOpenFailureSheetContent: Equatable, Sendable {
    public enum Row: CaseIterable, Sendable {
        /// 404 or 410: the link ran out.
        case expired
        /// Any other answer, a failed secure connection, an oversized body: it may be gone.
        case unavailable
        /// No key after the `#`, or a share-host `/l/` link whose id is not whole.
        case cutOff
        /// The key is there, but the header check or unsealing fails.
        case linkDamaged
        /// 503: the server's off switch.
        case switchedOff
        /// 429 and the other 5xx.
        case serverProblem
        case offline
        /// A share-host URL that is not under `/l/`.
        case notAShareLink
        case fileDamaged
        case fileNeedsNewerApp
        case fileTooBig
        case fileDoesNotMatchLibrary
    }

    public let row: Row
    public let headline: String
    public let line: String
    /// Try Again (filled) and Close; every other row has one OK.
    public let isRetryable: Bool
    /// The public id of a link to offer "Report this link" for, under OK. Only the cut-off row has it, and only when
    /// the link's 32-character id is whole. It is a link id and nothing else: never the key.
    public let reportLinkID: String?

    public var offersReport: Bool { reportLinkID != nil }

    public init(row: Row, reportLinkID: String? = nil) {
        self.row = row
        self.reportLinkID = row == .cutOff ? reportLinkID.flatMap(ShareLinkReport.validLinkId) : nil
        switch row {
        case .expired:
            (headline, line) = ("This link has expired.", "Ask your friend to share it again.")
        case .unavailable:
            (headline, line) = ("This link isn't available.", "It may have expired, or been removed. Ask your friend to share it again.")
        case .cutOff:
            (headline, line) = ("This link is cut off.", "Copy the whole link from the message and open it again.")
        case .linkDamaged:
            (headline, line) = ("This link couldn't be opened.", "It may have been damaged on the way. Ask your friend to share it again.")
        case .switchedOff:
            (headline, line) = ("Links are switched off for now.", "Ask your friend to send the Margins as a file.")
        case .serverProblem:
            (headline, line) = ("The server had a problem.", "Try again in a minute.")
        case .offline:
            (headline, line) = ("You're offline.", "Connect to the internet, then tap Try Again.")
        case .notAShareLink:
            (headline, line) = ("This isn't a link to a friend's Margins.", "Copy the whole link from the message and try again.")
        case .fileDamaged:
            (headline, line) = ("This file couldn't be opened.", "It may have been damaged on the way. Ask your friend to send it again.")
        case .fileNeedsNewerApp:
            (headline, line) = ("This needs a newer Spoken Margins.", "Your friend made this with a newer version. Update the app to hear it.")
        case .fileTooBig:
            (headline, line) = ("This file is too big to open.", "Ask your friend to send fewer Margins at a time.")
        case .fileDoesNotMatchLibrary:
            (headline, line) = ("These Margins don't match your copy.",
                                "Check you have the same copy and edition, then open them again. If it still fails, ask your friend to send them again.")
        }
        switch row {
        case .serverProblem, .offline: isRetryable = true
        default: isRetryable = false
        }
    }

    /// A failed download of the parsed link `linkID`, so the id is whole.
    public init(_ failure: ShareLinkPacketDownloader.Failure, linkID: String) {
        switch failure {
        case .offline: self.init(row: .offline)
        case .expired: self.init(row: .expired)
        case .serverProblem: self.init(row: .serverProblem)
        case .switchedOff: self.init(row: .switchedOff)
        case .expiredOrUnreachable: self.init(row: .unavailable)
        case .cutOff: self.init(row: .cutOff, reportLinkID: linkID)
        case .damaged: self.init(row: .linkDamaged)
        }
    }

    /// A URL on a share host that `ShareLinkURL` does not accept: anything under `/l/` (a short, long or non-hex id, or
    /// a longer path) is cut off, and the rest of the site is not a link to a friend's Margins. Whatever
    /// `ShareLinkURL` accepts is a whole id.
    public init(unparsedShareHostURL url: URL) {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard path.hasPrefix("/l/") else {
            self.init(row: .notAShareLink)
            return
        }
        // The id is the first part after `/l/`; offer the report page only when it is a whole id.
        let id = path.dropFirst(3).prefix { $0 != "/" }
        self.init(row: .cutOff, reportLinkID: String(id))
    }
}
