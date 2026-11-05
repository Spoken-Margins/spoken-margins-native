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
        let probe: PublicSourceVerifier.Probe = hermetic
            ? { _, _ in throw URLError(.notConnectedToInternet) }
            : PublicSourceTransport.probe
        return PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe))
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

    /// The share review's note (#3449): how many scene summaries the packet will leave out. The check runs first, so a
    /// public source is not told its summaries stay home. The count is read from the same rule the packet uses.
    func refreshWithheldMapNote() async {
        guard let store = try? requireStore() else { return }
        let itemId = selectedItem.id
        await PublicSourceChecks.ensureMark(itemId: itemId, store: store, timeout: PublicSourceChecks.shareTimeout)
        let count = try? await StoreReader(store).read(priority: .userInitiated) { store -> Int in
            let item = try store.loadItem(id: itemId)
            return SharedMarginExport.withheldSceneCount(
                try store.loadPortableListeningMapProposals(itemId: itemId),
                currentProposalID: try store.loadResolvedListeningMapProjection(itemId: itemId)?.proposalId,
                for: item)
        }
        guard selectedItem.id == itemId else { return }
        sharingState.withheldMapSceneCount = count ?? 0
    }
}
