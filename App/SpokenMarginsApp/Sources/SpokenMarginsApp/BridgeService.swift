import SwiftUI
import SessionKit

/// App-owned access to the public bridge documents. Consumers ask for a snapshot
/// at the point of use so a cached 'on' state cannot outlive the config's expiry.
/// Construction and ordinary app startup make no server requests. Following a
/// site without a feed is a separate change (#315).
@MainActor
final class BridgeService: ObservableObject {
    private let store: BridgeManifestStore?

    init(store: BridgeManifestStore?) {
        self.store = store
    }

    func current(now: Date = Date()) async -> BridgeSnapshot {
        guard let store else { return BridgeSnapshot(state: .off(.noConfig), manifest: nil) }
        return await store.current(now: now)
    }

    @discardableResult
    func refresh(now: Date = Date()) async -> BridgeRefreshOutcome {
        guard let store else { return .off(.noConfig) }
        return await store.refresh(now: now)
    }

    static func makeStore() -> BridgeManifestStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(buildString), build > 0 else { return nil }
        return BridgeManifestStore(
            cacheDirectory: support.appending(path: "Bridge", directoryHint: .isDirectory),
            appBuild: build,
            fetch: BridgePublicTransport.fetch
        )
    }
}

