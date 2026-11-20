import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// One `ListLinkRunner` per store (#4046 PR 6), so two requests share one runner and queue behind each other instead of
/// racing. The runner, the checker and the store actor all work off the main thread.
@MainActor
final class ListLinkRunnerHolder {
    static let shared = ListLinkRunnerHolder()
    private var runner: ListLinkRunner?
    private var runnerStore: SQLiteSessionStore?

    func runner(for store: SQLiteSessionStore) -> ListLinkRunner {
        if let runner, runnerStore === store { return runner }
        let made = ListLinkRunner(
            store: ListLinksStore(store: store),
            checker: ListLinkChecker(session: ListLinkTransport.makeSession()))
        runner = made
        runnerStore = store
        return made
    }
}

/// Thin wiring from Following's refresh to `ListLinkRunner`. Which triggers read a list address, and which links are due,
/// are SessionKit's (`FollowedRefreshTrigger`, `ListLinkSchedule`).
extension Gate1AppModel {
    /// Starts reading the list addresses that are due, for a refresh a listener asked for, and returns at once. Any other
    /// trigger returns before the store or the network is touched. A failed or cancelled check changes nothing the listener
    /// sees: a status and a waiting change are stored for the screens that read them (PR 7a, 7b).
    func startListLinkCheck(trigger: FollowedRefreshTrigger) {
        guard trigger.checksListLinks, let store else { return }
        ListLinkRunnerHolder.shared.runner(for: store).runWithoutWaiting(trigger: trigger)
    }
}
