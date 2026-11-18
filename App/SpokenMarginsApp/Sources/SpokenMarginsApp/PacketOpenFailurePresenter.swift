import Foundation
import SessionKit

/// The state of the sheet that says a friend's share link or `.spokenmargins` file could not be opened (#3801).
///
/// It holds what the sheet shows and nothing about the import itself. `openShareLink` and the packet import call
/// `present`; the sheet's buttons call `tryAgain` and `close`. A second failure while the sheet is up replaces its
/// content in place (the latest wins), and a success closes it without telling the first-launch drawer anything.
@MainActor
final class PacketOpenFailurePresenter: ObservableObject {
    struct Presented: Identifiable {
        /// Stays the same while the sheet is up, so a new failure swaps the words without the sheet leaving.
        let id: UUID
        let content: PacketOpenFailureSheetContent
        fileprivate let retry: (@MainActor () -> Void)?

        /// Try Again (filled) and Close, as the content asks, and only when there is something to run again.
        var showsTryAgain: Bool { content.isRetryable && retry != nil }
    }

    @Published private(set) var presented: Presented?
    /// A Try Again is running: its button shows a spinner and the sheet stays.
    @Published private(set) var isRetrying = false
    /// The listener closed the sheet (OK, Close or a swipe) and the first-launch drawer has not been told yet.
    private var owesCloseNotice = false
    /// Counts the failures put up, so an open that began earlier can tell whether the sheet has said anything new since.
    private(set) var generation = 0
    /// Stops the open a Try Again started. Set by the import coordinator, which owns the opener.
    var cancelRunningOpen: (@MainActor () -> Void)?

    /// Shows `content`, or swaps the words of the sheet that is already up. `retry` runs the same open again.
    func present(_ content: PacketOpenFailureSheetContent, retry: (@MainActor () -> Void)?) {
        presented = Presented(id: presented?.id ?? UUID(), content: content, retry: retry)
        generation += 1
        isRetrying = false
        owesCloseNotice = true
    }

    func tryAgain() {
        guard let retry = presented?.retry, presented?.showsTryAgain == true, !isRetrying else { return }
        isRetrying = true
        retry()
    }

    /// OK, Close, or the sheet swiped away. Closing during a Try Again also stops that open: the listener has given up
    /// on the link, so a late answer must not bring a sheet back or open a review under them.
    func close() {
        guard presented != nil else { return }
        if isRetrying { cancelRunningOpen?() }
        presented = nil
        isRetrying = false
    }

    /// The link or file opened after all (a Try Again that worked): the sheet goes, and nobody is told it failed.
    func succeeded() {
        guard presented != nil else { return }
        owesCloseNotice = false
        presented = nil
        isRetrying = false
    }

    /// An open that began when the sheet was at `generation` has ended. Opened: the sheet goes and nobody is told it
    /// failed. Not opened and the sheet has said nothing new since (the failure went to a banner, or the open was
    /// cancelled): its words are out of date and a banner behind a sheet cannot be read, so it closes as if the listener
    /// had, and the drawer it withdrew comes back.
    func openEnded(opened: Bool, since generation: Int) {
        if opened {
            succeeded()
        } else if presented != nil, self.generation == generation {
            presented = nil
            isRetrying = false
        }
    }

    /// True once after the listener closed the sheet, so the first-launch drawer comes back once the sheet is gone.
    func takeCloseNotice() -> Bool {
        guard owesCloseNotice, presented == nil else { return false }
        owesCloseNotice = false
        return true
    }
}
