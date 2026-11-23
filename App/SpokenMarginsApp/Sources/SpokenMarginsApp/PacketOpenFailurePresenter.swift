import Foundation
import SessionKit

/// The sheet that says a friend's share link or `.spokenmargins` file could not be opened (#3801).
///
/// It holds what the sheet shows and nothing about the import itself; the rules are `PacketOpenFailureSheetState`'s,
/// tested on the host. `openShareLink` and the packet import call `present`; the sheet's buttons call `tryAgain` and
/// `close`.
@MainActor
final class PacketOpenFailurePresenter: ObservableObject {
    typealias Presented = PacketOpenFailureSheetState.Presented

    @Published private(set) var state = PacketOpenFailureSheetState()
    private var retry: (@MainActor () -> Void)?
    /// Stops the open a Try Again started. Set by the import coordinator, which owns the opener.
    var cancelRunningOpen: (@MainActor () -> Void)?

    var presented: Presented? { state.presented }
    /// A Try Again is running: its button shows a spinner and the sheet stays.
    var isRetrying: Bool { state.isRetrying }
    /// Counts the failures put up, so an open that began earlier can tell whether the sheet has said anything new since.
    var generation: Int { state.generation }

    /// Shows `content`, or swaps the words of the sheet that is already up. `retry` runs the same open again.
    /// `endsOpen`: this failure ends the open that was running (a download that failed); a refused file doesn't, its open
    /// ends with `openEnded`.
    func present(_ content: PacketOpenFailureSheetContent, retry: (@MainActor () -> Void)?, endsOpen: Bool = false) {
        self.retry = retry
        state.present(content, canRetry: retry != nil, endsOpen: endsOpen)
    }

    func tryAgain() {
        guard let retry, state.tryAgain() else { return }
        retry()
    }

    /// The listener opened another link, not a Try Again: neither Close nor Try Again may touch the opener, which now
    /// runs that link.
    func anotherLinkStarted() {
        retry = nil
        state.anotherLinkStarted()
    }

    /// OK, Close, or the sheet swiped away. Closing during a Try Again also stops that open.
    func close() {
        if state.close() { cancelRunningOpen?() }
        retry = nil
    }

    /// The link or file opened after all (a Try Again that worked): the sheet goes, and nobody is told it failed.
    func succeeded() {
        state.succeeded()
    }

    /// An open that began when the sheet was at `generation` has ended; see `PacketOpenFailureSheetState.openEnded`.
    func openEnded(opened: Bool, since token: PacketOpenFailureSheetState.OpenToken) {
        if state.openEnded(opened: opened, since: token) { onCloseNotice?() }
    }

    /// What an open takes when it starts and passes back to `openEnded`.
    var openToken: PacketOpenFailureSheetState.OpenToken { state.openToken }

    /// Tells the first-launch drawer that the failure it was waiting on is over. Installed where the presenter is built,
    /// so neither route can hand out the notice before a handler exists. Called only from `sheetDismissed` and
    /// `openEnded`, the state's two routes.
    var onCloseNotice: (@MainActor () -> Void)?

    /// Told by the import when a friend's file opened its item; the first-launch drawer's order listens (#4834).
    var onFriendItemOpened: (@MainActor (_ itemId: String) -> Void)?
    func friendItemOpened(itemId: String) { onFriendItemOpened?(itemId) }

    /// The sheet's `onDismiss`: it has fully left, so the first-launch drawer comes back now if it is due. True when it
    /// told the drawer.
    @discardableResult
    func sheetDismissed() -> Bool {
        guard state.sheetDismissed() else { return false }
        onCloseNotice?()
        return true
    }
}
