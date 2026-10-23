import Foundation

// Seams I3 and I11, app side. Modelled on SourceCatalogStore: fetch small documents
// from the owner's server over https on one pinned host, cap their size, cache what
// verified, and keep what the app already has when anything fails. Unlike the
// catalog there is no bundled snapshot: with no usable config the bridge is off,
// and bridged sources read "not updating". Nothing else in the app depends on it.

public struct BridgeManifestPolicy: Equatable, Sendable {
    public static let production = BridgeManifestPolicy(
        configURL: ProductServer.url(path: "/api/v1/config.json"),
        manifestURL: ProductServer.url(path: "/bridge/v1/manifest.json"),
        trustedHost: ProductServer.host
    )

    public var configURL: URL
    public var manifestURL: URL
    public var trustedHost: String
    public var maximumConfigAge: TimeInterval

    public init(configURL: URL, manifestURL: URL, trustedHost: String, maximumConfigAge: TimeInterval = ServerFeatureGate.maximumConfigAge) {
        self.configURL = configURL
        self.manifestURL = manifestURL
        self.trustedHost = trustedHost
        self.maximumConfigAge = maximumConfigAge
    }

    func isTrusted(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == trustedHost.lowercased() &&
        url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

/// What the app may use right now. `manifest` is nil whenever the bridge is off, and
/// also when it is on but no manifest has verified yet.
public struct BridgeSnapshot: Equatable, Sendable {
    public var state: ServerFeatureState
    public var manifest: BridgeManifest?

    public init(state: ServerFeatureState, manifest: BridgeManifest?) {
        self.state = state
        self.manifest = state.isOn ? manifest : nil
    }

    /// Whether bridged sources can show new items; otherwise the UI says "not updating".
    public var isUpdating: Bool { state.isOn && manifest != nil }
}

public enum BridgeRefreshError: Error, Equatable, Sendable {
    case untrustedURL
    /// Offline, timeout, TLS.
    case network
    case httpStatus(Int)
    case oversizedManifest
    case malformedManifest
}

public enum BridgeRefreshOutcome: Equatable, Sendable {
    /// A new manifest verified and was cached.
    case updated(sourceCount: Int)
    /// The manifest is the same as the one held.
    case unchanged
    /// The bridge is off; the manifest was not fetched.
    case off(ServerFeatureOffReason)
    /// The config said on but the manifest failed; the previous one stays.
    case failed(BridgeRefreshError)
}

public actor BridgeManifestStore {
    private let cacheDirectory: URL
    private let policy: BridgeManifestPolicy
    private let appBuild: Int
    private let fetch: SourceHTTPFetch
    private let fileManager: FileManager
    private var loaded = false
    private var config: CachedServerConfig?
    private var manifest: BridgeManifest?
    private var manifestData: Data?

    public init(cacheDirectory: URL, appBuild: Int, policy: BridgeManifestPolicy = .production, fileManager: FileManager = .default, fetch: @escaping SourceHTTPFetch) {
        self.cacheDirectory = cacheDirectory
        self.appBuild = appBuild
        self.policy = policy
        self.fileManager = fileManager
        self.fetch = fetch
    }

    private var configCacheURL: URL { cacheDirectory.appendingPathComponent("server-config.json") }
    private var manifestCacheURL: URL { cacheDirectory.appendingPathComponent("bridge-manifest.json") }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: configCacheURL) {
            // An unreadable cache fails closed, the same as a malformed download.
            config = (try? JSONDecoder().decode(CachedServerConfig.self, from: data))
                ?? CachedServerConfig(config: nil, fetchedAt: .distantPast, malformed: true)
        }
        if let data = try? Data(contentsOf: manifestCacheURL), let decoded = try? BridgeManifestVerifier.manifest(from: data) {
            manifest = decoded
            manifestData = data
        }
    }

    /// The bridge as the app may use it now. Works offline; never touches the network.
    public func current(now: Date = Date()) -> BridgeSnapshot {
        loadCache()
        let state = ServerFeatureGate.state(of: ServerService.bridge, cached: config, now: now, appBuild: appBuild, maximumAge: policy.maximumConfigAge)
        return BridgeSnapshot(state: state, manifest: state.isOn ? manifest : nil)
    }

    /// Whether another server feature, such as `ServerService.maps`, may be used now. The
    /// config is the same document for every feature; this store is where the app caches it.
    public func state(of service: String, now: Date = Date()) -> ServerFeatureState {
        loadCache()
        return ServerFeatureGate.state(of: service, cached: config, now: now, appBuild: appBuild, maximumAge: policy.maximumConfigAge)
    }

    /// Fetches only the config, for a feature that needs a fresh switch but not the manifest.
    /// Never throws; the gate decides what a failure means.
    public func refreshConfigOnly(now: Date = Date()) async {
        loadCache()
        await refreshConfig(now: now)
    }

    /// Fetches the config, then the manifest only if the bridge is on. Never throws:
    /// on any failure the app keeps what it had, and the gate decides what that means.
    @discardableResult
    public func refresh(now: Date = Date()) async -> BridgeRefreshOutcome {
        loadCache()
        await refreshConfig(now: now)
        let state = current(now: now).state
        guard state.isOn else { return .off(offReason(state)) }
        do {
            guard policy.isTrusted(policy.manifestURL) else { throw BridgeRefreshError.untrustedURL }
            let data = try await fetchBody(policy.manifestURL, maximumBytes: BridgeManifestVerifier.maximumBytes)
            if data == manifestData { return .unchanged }
            let decoded: BridgeManifest
            do {
                decoded = try BridgeManifestVerifier.manifest(from: data)
            } catch BridgeManifestError.oversized {
                throw BridgeRefreshError.oversizedManifest
            } catch {
                throw BridgeRefreshError.malformedManifest
            }
            try? write(data, to: manifestCacheURL)
            manifest = decoded
            manifestData = data
            return .updated(sourceCount: decoded.sources.count)
        } catch let error as BridgeRefreshError {
            return .failed(error)
        } catch {
            return .failed(.network)
        }
    }

    private func refreshConfig(now: Date) async {
        guard policy.isTrusted(policy.configURL) else {
            store(CachedServerConfig(config: config?.config, fetchedAt: config?.fetchedAt ?? now, malformed: true))
            return
        }
        let status: Int
        let body: Data
        do {
            (status, body) = try await fetch(policy.configURL, ServerFeatureGate.maximumConfigBytes)
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            store(CachedServerConfig(config: config?.config, fetchedAt: config?.fetchedAt ?? now, malformed: true))
            return
        } catch {
            // Unreachable: keep what we have. The gate turns it off once it's a week old.
            return
        }
        switch status {
        case 200..<300:
            store(ServerFeatureGate.merge(fetched: body, at: now, into: config))
        case 404, 410:
            // The owner removed the config: that is "off", not a transient failure.
            store(CachedServerConfig(config: nil, fetchedAt: now))
        default:
            // A server error is treated like an outage: keep what we have.
            return
        }
    }

    private func store(_ updated: CachedServerConfig) {
        config = updated
        if let data = try? JSONEncoder().encode(updated) {
            try? write(data, to: configCacheURL)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func offReason(_ state: ServerFeatureState) -> ServerFeatureOffReason {
        if case let .off(reason) = state { return reason }
        return .switchedOff
    }

    private func fetchBody(_ url: URL, maximumBytes: Int) async throws -> Data {
        let status: Int
        let body: Data
        do {
            (status, body) = try await fetch(url, maximumBytes)
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            throw BridgeRefreshError.oversizedManifest
        } catch {
            throw BridgeRefreshError.network
        }
        guard (200..<300).contains(status) else { throw BridgeRefreshError.httpStatus(status) }
        return body
    }
}
