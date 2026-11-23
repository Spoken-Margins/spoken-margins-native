import Foundation
import SessionKit

/// The one Not for me store (#4285 PR 6). It lives beside the database (`Application Support/not-for-me.json` in
/// the app; a test's own folder when the test moves the database), and what to record and how to match lives in
/// SessionKit (`NotForMeStore`, `FollowedSourceCoordinator`); the model only wires it.
@MainActor
final class NotForMeHolder {
    /// Exists before the store, so the followed-source coordinator can be handed its provider at once.
    let box = NotForMeSnapshotBox()
    private var store: NotForMeStore?

    func store(directory: URL) -> NotForMeStore {
        if let store { return store }
        let created = NotForMeStore(fileURL: directory.appending(path: NotForMeStore.fileName), box: box)
        store = created
        return created
    }
}

extension Gate1AppModel {
    /// What the drawer and the coordinator read without awaiting the store. Empty until the first load.
    var notForMeSnapshot: NotForMeSnapshot { notForMe.box.current }

    /// The coordinator's `suppressedEntry` provider, backed by the store's box.
    var notForMeSuppressedEntry: @Sendable (_ feedKey: String, _ entryKey: String) -> Bool {
        notForMe.box.suppressedEntry
    }

    func requireNotForMeStore() throws -> NotForMeStore {
        try notForMe.store(directory: databaseURL().deletingLastPathComponent())
    }

    /// Read the marks before a followed-source refresh saves entries, so a launch refresh can't revive a marked
    /// episode. The store reads its file once; later calls return at once.
    func loadNotForMe() async {
        guard let store = try? requireNotForMeStore() else { return }
        await store.load()
    }

    /// Writes the mark for a followed show's episode. Returns whether it was written, so Undo knows whether to take
    /// one off. An episode with nothing to recognise it by, or a feed with no host, is dismissed without a mark.
    func markNotForMe(_ entry: FeedEntry) async -> Bool {
        guard let subscription = feedSubscriptions.first(where: { $0.id == entry.subscriptionId }),
              let store = try? requireNotForMeStore() else { return false }
        do {
            try await store.markItem(entry, of: subscription)
            return true
        } catch {
            diagnostics["notForMeMark"] = Self.notForMeFailure(error)
            return false
        }
    }

    func unmarkNotForMe(_ entry: FeedEntry) async {
        guard let subscription = feedSubscriptions.first(where: { $0.id == entry.subscriptionId }),
              let store = try? requireNotForMeStore() else { return }
        do {
            try await store.unmarkItem(entry, of: subscription)
        } catch {
            diagnostics["notForMeUnmark"] = Self.notForMeFailure(error)
        }
    }

    /// The store's own reasons by case name (`SafeErrorText` keeps an enum's case name); anything else by domain and
    /// code only, so no file path reaches Diagnostics.
    private static func notForMeFailure(_ error: Error) -> String {
        "failed:\(SafeErrorText.describe(error))"
    }
}
