import Foundation
import SessionKit

/// What Paste & go is waiting on while a link list arrives, and the Quick Folder's retry bookkeeping (#4683, Design
/// sections 2d and 2g). The model holds one, like `libraryCollections`, so `Gate1AppModel.swift` has only the
/// stored-property line.
@MainActor
final class LinkListArrivalState: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// A pasted reply is being read, or its list is being added.
        case reading
        /// The list arrived (the banner says how it went); Paste & go's sheet can close.
        case added
        /// Nothing was added. The message is shown under the bar and the sheet stays open.
        case refused(String)
    }

    @Published var phase: Phase = .idle

    /// Failed tries of Quick Folder lists, over `UserDefaults`, so a count survives a relaunch.
    let quickFolderRetry: LinkListRetryLedger

    /// Failed tries of saved handoff files (the Shortcuts action's lists), over `UserDefaults`, so a count survives a relaunch.
    let handoffRetry: LinkListRetryLedger

    /// True while `drainLinkListHandoffs()` runs, so two foregrounds at once can't read the same file twice.
    var isDrainingHandoffs = false

    /// Quick Folder files not to try again on their own until the app comes forward again: they waited offline or
    /// failed this time. Without it, the refresh that ends an import would start the next try at once and spend all
    /// three tries in a few seconds. Kept in memory, so a relaunch tries them again.
    private(set) var heldQuickFolderFiles: Set<String> = []

    init(
        quickFolderRetry: LinkListRetryLedger = LinkListRetryLedger(key: LinkListRetryLedger.quickFolderKey),
        handoffRetry: LinkListRetryLedger = LinkListRetryLedger(key: LinkListRetryLedger.handoffKey)
    ) {
        self.quickFolderRetry = quickFolderRetry
        self.handoffRetry = handoffRetry
    }

    func hold(_ fileID: String) { heldQuickFolderFiles.insert(fileID) }
    func isHeld(_ fileID: String) -> Bool { heldQuickFolderFiles.contains(fileID) }
    func releaseHeldFiles() { heldQuickFolderFiles.removeAll() }
}
