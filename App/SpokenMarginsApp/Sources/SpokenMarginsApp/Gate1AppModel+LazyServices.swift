import Foundation
import SessionKitPersistence

extension Gate1AppModel {
    func requireOfflineLedger(
        store: SQLiteSessionStore,
        rootDirectory: @autoclosure () throws -> URL
    ) rethrows -> OfflineStorageLedger {
        if let offlineStorageLedger { return offlineStorageLedger }
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: try rootDirectory())
        offlineStorageLedger = ledger
        return ledger
    }
}
