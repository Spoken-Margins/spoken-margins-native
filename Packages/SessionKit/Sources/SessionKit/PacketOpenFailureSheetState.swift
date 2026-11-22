import Foundation

/// The rules of the sheet that says a friend's share link or `.spokenmargins` file could not be opened (#3801). They
/// are here so they run on the host; the app's `PacketOpenFailurePresenter` publishes one, keeps the Try Again closure
/// and runs what these methods ask for.
///
/// A second failure while the sheet is up replaces its content in place (the latest wins), and a success closes it
/// without telling the first-launch drawer anything.
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
    /// The listener closed the sheet (OK, Close or a swipe) and the first-launch drawer has not been told yet.
    private var owesCloseNotice = false
    /// Counts the failures put up, so an open that began earlier can tell whether the sheet has said anything new since.
    public private(set) var generation = 0

    public init() {}

    /// Shows `content`, or swaps the words of the sheet that is already up.
    public mutating func present(_ content: PacketOpenFailureSheetContent, canRetry: Bool) {
        presented = Presented(id: presented?.id ?? UUID(), content: content, canRetry: canRetry)
        generation += 1
        isRetrying = false
        owesCloseNotice = true
    }

    /// Try Again was tapped. True when the open that failed should run again.
    public mutating func tryAgain() -> Bool {
        guard presented?.showsTryAgain == true, !isRetrying else { return false }
        isRetrying = true
        return true
    }

    /// The listener opened another link while the sheet was up. The opener runs one link at a time and now runs that
    /// one, having dropped any Try Again for it. So the spinner stops, a later Close stops nothing, and the old link's
    /// Try Again goes (the sheet keeps one OK): either would drop the link just tapped (the audit on PR #4597). The new
    /// link's own failure, if it fails, replaces these words.
    public mutating func anotherLinkStarted() {
        isRetrying = false
        if let presented { self.presented = Presented(id: presented.id, content: presented.content, canRetry: false) }
    }

    /// OK, Close, or the sheet swiped away. True when the open a Try Again started should stop: the listener has given
    /// up on the link, so a late answer must not bring a sheet back or open a review under them.
    public mutating func close() -> Bool {
        guard presented != nil else { return false }
        let stopsRetry = isRetrying
        presented = nil
        isRetrying = false
        return stopsRetry
    }

    /// The link or file opened after all (a Try Again that worked): the sheet goes, and nobody is told it failed.
    public mutating func succeeded() {
        guard presented != nil else { return }
        owesCloseNotice = false
        presented = nil
        isRetrying = false
    }

    /// An open that began when the sheet was at `generation` has ended. Opened: the sheet goes and nobody is told it
    /// failed. Not opened and the sheet has said nothing new since (the failure went to a banner, or the open was
    /// cancelled): its words are out of date and a banner behind a sheet cannot be read, so it closes as if the listener
    /// had, and the drawer it withdrew comes back.
    public mutating func openEnded(opened: Bool, since generation: Int) {
        if opened {
            succeeded()
        } else if presented != nil, self.generation == generation {
            presented = nil
            isRetrying = false
        }
    }

    /// True once after the listener closed the sheet, so the first-launch drawer comes back once the sheet is gone.
    public mutating func takeCloseNotice() -> Bool {
        guard owesCloseNotice, presented == nil else { return false }
        owesCloseNotice = false
        return true
    }
}
