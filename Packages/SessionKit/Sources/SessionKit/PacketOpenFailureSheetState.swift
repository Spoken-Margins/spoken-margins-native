import Foundation

/// The rules of the sheet that says a friend's share link or `.spokenmargins` file could not be opened (#3801). They
/// are here so they run on the host; the app's `PacketOpenFailurePresenter` publishes one, keeps the Try Again closure
/// and runs what these methods ask for.
///
/// A second failure while the sheet is up replaces its content in place (the latest wins), and a success closes it
/// without telling the first-launch drawer anything.
///
/// **When the first-launch drawer is told (#4834).** This type is the only place that decides, and it hands the notice
/// out by exactly two calls, each take-once:
///
/// - `sheetDismissed()`, from the sheet's own `onDismiss`: the sheet has fully left, so the drawer may present.
/// - `openEnded(opened:since:)`, when no sheet is up or leaving to carry it: a link that ends with nothing to show.
///
/// The notice is owed from a failure until it is handed out, and is never handed out while an open is still running (a
/// second link downloading, or a Try Again): that open may yet succeed, and the drawer would be withdrawn again under
/// it. An open running is ended by `openEnded`, by a failure that `present` says ends it, or by closing a Try Again.
public struct PacketOpenFailureSheetState: Equatable, Sendable {
    public struct Presented: Identifiable, Equatable, Sendable {
        /// Stays the same while the sheet is up, so a new failure swaps the words without the sheet leaving.
        public let id: UUID
        public let content: PacketOpenFailureSheetContent
        /// Whether the open that failed can be run again.
        public let canRetry: Bool

        /// Try Again (filled) and Close, as the content asks, and only when there is something to run again.
        public var showsTryAgain: Bool { content.isRetryable && canRetry }
    }

    public private(set) var presented: Presented?
    /// A Try Again is running: its button shows a spinner and the sheet stays.
    public private(set) var isRetrying = false
    /// Counts the failures put up, so an open that began earlier can tell whether the sheet has said anything new since.
    public private(set) var generation = 0
    /// A failure was shown and the first-launch drawer has not been told yet.
    private var owesNotice = false
    /// An open is running that can still succeed or fail: a Try Again, or a link opened while the sheet was up.
    private var openRunning = false
    /// The sheet has been closed (by the listener or by us) and its `onDismiss` has not run yet.
    private var sheetLeaving = false
    /// Counts the opens that have started, so only the newest one's end can touch the running flag: a link that was
    /// replaced (or a Try Again that was closed) may still report after the next one began.
    private var openSerial = 0

    /// What an open takes when it starts and hands back to `openEnded`.
    public struct OpenToken: Equatable, Sendable {
        fileprivate let words: Int
        fileprivate let serial: Int
    }

    /// The token for the open that is about to start (take it after `tryAgain` or `anotherLinkStarted`).
    public var openToken: OpenToken { OpenToken(words: generation, serial: openSerial) }

    public init() {}

    /// Shows `content`, or swaps the words of the sheet that is already up. `endsOpen`: this failure is the end of the
    /// open that was running (a download that failed). A refused file passes false: its open ends with `openEnded`.
    public mutating func present(_ content: PacketOpenFailureSheetContent, canRetry: Bool, endsOpen: Bool = false) {
        presented = Presented(id: presented?.id ?? UUID(), content: content, canRetry: canRetry)
        generation += 1
        isRetrying = false
        owesNotice = true
        sheetLeaving = false
        if endsOpen { openRunning = false }
    }

    /// Try Again was tapped. True when the open that failed should run again.
    public mutating func tryAgain() -> Bool {
        guard presented?.showsTryAgain == true, !isRetrying else { return false }
        isRetrying = true
        openRunning = true
        openSerial += 1
        return true
    }

    /// The listener opened another link while the sheet was up. The opener runs one link at a time and now runs that
    /// one, having dropped any Try Again for it. So the spinner stops, a later Close stops nothing, and the old link's
    /// Try Again goes (the sheet keeps one OK): either would drop the link just tapped (the audit on PR #4597). The new
    /// link's own failure, if it fails, replaces these words. Any notice already owed waits for that link to end.
    public mutating func anotherLinkStarted() {
        isRetrying = false
        openRunning = true
        openSerial += 1
        if let presented { self.presented = Presented(id: presented.id, content: presented.content, canRetry: false) }
    }

    /// OK, Close, or the sheet swiped away. True when the open a Try Again started should stop: the listener has given
    /// up on the link, so a late answer must not bring a sheet back or open a review under them.
    public mutating func close() -> Bool {
        guard presented != nil else { return false }
        let stopsRetry = isRetrying
        presented = nil
        isRetrying = false
        sheetLeaving = true
        if stopsRetry {
            openRunning = false
            openSerial += 1
        }
        return stopsRetry
    }

    /// The link or file opened after all (a Try Again that worked): the sheet goes, and nobody is told it failed.
    public mutating func succeeded() {
        owesNotice = false
        openRunning = false
        isRetrying = false
        if presented != nil {
            presented = nil
            sheetLeaving = true
        }
    }

    /// An open that began when the sheet was at `generation` has ended. Opened: the sheet goes and nobody is told it
    /// failed. Not opened and the sheet has said nothing new since (the failure went to a banner, or the open was
    /// cancelled): its words are out of date and a banner behind a sheet cannot be read, so it closes as if the listener
    /// had, and the drawer it withdrew comes back. True when the notice is due now: no sheet is up or leaving to
    /// carry it, so the caller tells the drawer.
    @discardableResult
    public mutating func openEnded(opened: Bool, since token: OpenToken) -> Bool {
        // An open that was replaced says nothing: the newer one is still running and owns the flag.
        guard token.serial == openSerial else { return false }
        if opened {
            succeeded()
            return false
        }
        openRunning = false
        if generation == token.words, presented != nil {
            presented = nil
            isRetrying = false
            sheetLeaving = true
            owesNotice = true
        }
        return takeNoticeIfDue()
    }

    /// The sheet has fully left. True once, when the first-launch drawer is due to be told.
    @discardableResult
    public mutating func sheetDismissed() -> Bool {
        guard presented == nil else { return false }
        sheetLeaving = false
        return takeNoticeIfDue()
    }

    private mutating func takeNoticeIfDue() -> Bool {
        guard owesNotice, presented == nil, !sheetLeaving, !openRunning else { return false }
        owesNotice = false
        return true
    }
}
