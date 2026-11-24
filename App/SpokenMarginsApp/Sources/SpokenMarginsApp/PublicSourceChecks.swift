import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSharing

/// The app's one `PublicSourceMarker` (#3449): the check that marks a source public, so its model-written scene text may
/// leave the phone (`MapTextDisclosure`).
///
/// It runs only on a listener's action: when an item is added (`reportAddedToLibrary`), on the Prepare Listening Map tap,
/// and when a share or an export that carries the Listening Map is built. No background path calls it
/// (`scripts/tests/test_public_source_check_callers.py`). The request is anonymous: no cookies, credentials or install
/// identity, and no redirect taken without the verifier's say-so (`PublicSourceTransport`).
enum PublicSourceChecks {
    /// Time a share tap waits for the check. Offline or slower counts as no mark for that share; the next tap tries again.
    static let shareTimeout: Duration = .seconds(6)

    /// Tests replace this with a marker backed by canned answers. A unit test or UI-test launch never reaches the network.
    @MainActor static var marker: PublicSourceMarker = makeLive()

    @MainActor static func makeLive() -> PublicSourceMarker {
        var hermetic = Gate1AppModel.isRunningUnitTests
        #if DEBUG
        hermetic = hermetic || UITestingHooks.isActive
        #endif
        let offline: PublicSourceVerifier.Probe = { @Sendable _, _ in throw URLError(.notConnectedToInternet) }
        return PublicSourceMarker(verifier: PublicSourceVerifier(probe: hermetic ? offline : PublicSourceTransport.probe))
    }

    /// The engine with the checker installed, so an export that carries the Listening Map checks its source first.
    /// Kept here so the central model does not grow (the hot-file ratchet).
    @MainActor static func attached(to engine: SessionEngine) -> SessionEngine {
        engine.publicSourceMarker = marker
        return engine
    }

    /// Checks the item and records the mark, off the main thread. The item is untouched when the check finds nothing.
    @MainActor @discardableResult
    static func ensureMark(itemId: String, store: any SessionRepository, timeout: Duration = PublicSourceVerifier.defaultTimeout) async -> PublicSourceVerifier.Outcome {
        await marker.ensureMark(itemId: itemId, repository: store, timeout: timeout)
    }
}

extension Gate1AppModel {
    /// Starts the check for an item the listener just acted on, without waiting for it. A tap or an add began it; the
    /// answer is in the store by the time they share. Does nothing for a source that has no public copy to check.
    func startPublicSourceCheck(itemId: String) {
        guard let store else { return }
        Task { await PublicSourceChecks.ensureMark(itemId: itemId, store: store) }
    }

    /// The share review's note (#3449, #4635): how many scene summaries the packet will leave out. The count is read
    /// first, from the same rule the packet uses; the public-source check runs only when something would be withheld, so
    /// an item with no model-written scenes, or one already marked public, contacts nobody. When the check runs, the count
    /// is read again, so a source it now finds public is not told its summaries stay home. The Share sheet the listener
    /// opened is the only caller.
    func refreshWithheldMapNote(store: SQLiteSessionStore) async {
        let itemId = selectedItem.id
        await recountWithheldMapNote(store: store, itemId: itemId)
        guard !Task.isCancelled, selectedItem.id == itemId, sharingState.withheldMapSceneCount > 0 else { return }
        await PublicSourceChecks.ensureMark(itemId: itemId, store: store, timeout: PublicSourceChecks.shareTimeout)
        await recountWithheldMapNote(store: store, itemId: itemId)
    }

    /// Reads the withheld-scene count for `itemId` from the store, off the main thread, and shows it while that item is
    /// still the one being shared. It makes no request: the packet build calls it after its own check, so Review and the
    /// recipient preview match what was sent.
    func recountWithheldMapNote(store: SQLiteSessionStore, itemId: String) async {
        let count = try? await StoreReader(store).read(priority: .userInitiated) { store -> Int in
            let item = try store.loadItem(id: itemId)
            return SharedMarginExport.withheldSceneCount(
                try store.loadPortableListeningMapProposals(itemId: itemId),
                currentProposalID: try store.loadResolvedListeningMapProjection(itemId: itemId)?.proposalId,
                for: item)
        }
        guard !Task.isCancelled, selectedItem.id == itemId else { return }
        sharingState.withheldMapSceneCount = count ?? 0
    }
}
