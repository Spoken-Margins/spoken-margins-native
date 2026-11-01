import Foundation
import SessionKit
import SessionKitPersistence

/// The startup work each store configuration runs: save the storage budget, adopt and trim offline files, then
/// refresh Following and the guided tour. Moved out of the central model for #2195.
extension Gate1AppModel {
    /// Holds the model weakly and stops when the model goes away. It used to hold the model strongly, so a dropped
    /// model lived on until the tour download ended, and its SQLite calls then ran on the main thread during
    /// whatever came next. Against another connection to the same file each one could wait out the store's 1 s
    /// busy timeout (#2195).
    func startOfflineServices(store: SQLiteSessionStore, ledger: OfflineStorageLedger) {
        offlineServicesStartupTasks.append(Task { [weak self] in
            guard let limitGB = self?.offlineStorageLimitGB, !Task.isCancelled else { return }
            let budget = OfflineStorageBudget(limitBytes: Int64(limitGB) * OfflineStorageBudget.bytesPerGigabyte)
            try? await StoreReader(store).readInOrder(OfflineStorageBudget.saveOrderKey) { try $0.saveOfflineStorageBudget(budget) }
            try? await ledger.adoptExistingAssets()
            guard !Task.isCancelled else { return }
            let residualOverage = try? await ledger.enforceBudget()
            let reconciled = await ledger.lastReconciliation?.summary ?? "failed"
            let ledgerBytes = try? await ledger.inventoryBytes()
            let filesystemBytes = await ledger.directFilesystemBytes()
            // From here `self` is taken afresh after every await; the scoped `model` ends with its block.
            do {
                guard !Task.isCancelled, let model = self else { return }
                model.diagnostics["offlineLedgerReconciled"] = reconciled
                model.diagnostics["offlineLedgerBytes"] = "\(ledgerBytes ?? 0)"
                model.diagnostics["offlineFilesystemBytes"] = "\(filesystemBytes)"
                model.diagnostics["offlineResidualOverageBytes"] = "\(residualOverage ?? 0)"
                model.tryRefreshOfflineStorageUsage()
                await model.performFollowedSourceRefresh(force: false)
            }
            // A model built by a test must not ask the production server for the tour: on a runner with a network
            // the answer landed mid-test and put a `guided-onboarding` row into a library the test had counted (#2772).
            guard !Task.isCancelled,
                  !Gate1AppModel.isRunningUnitTests,
                  !UserDefaults.standard.bool(forKey: Gate1AppModel.guidedOnboardingTombstoneKey),
                  let coordinator = self?.guidedOnboardingCoordinator,
                  self?.store != nil else { return }
            let refreshed: Result<GuidedOnboardingPayload, Error>
            do { refreshed = .success(try await coordinator.refresh()) } catch { refreshed = .failure(error) }
            guard !Task.isCancelled else { return }
            await self?.applyGuidedOnboardingRefresh(refreshed)
        })
    }
}
