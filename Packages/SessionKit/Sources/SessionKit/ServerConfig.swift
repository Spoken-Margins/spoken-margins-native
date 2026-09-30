import Foundation

// Seam I11: the kill switch for every Spoken Margins server feature. The server
// publishes one small static document (research/B4/DESIGN.md §4); the app reads
// it before using any server feature and fails closed. Anything in doubt (no
// config yet, a malformed one, a switched-off or missing service, a config not
// refreshed for a week, a build the owner switched off) means the feature is off.
// The rest of the app never depends on this document.

public struct ServerConfig: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.server-config"
    public static let version = 1

    public struct Service: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// The feature is off for app builds below this number.
        public var minimumBuild: Int?

        public init(enabled: Bool, minimumBuild: Int? = nil) {
            self.enabled = enabled
            self.minimumBuild = minimumBuild
        }
    }

    public var schema: String
    public var version: Int
    /// Only goes up. A document with a lower serial than the cached one is ignored,
    /// so a stale cache or replay can't switch a feature back on.
    public var serial: Int
    public var checkAfterSeconds: Int?
    public var services: [String: Service]

    public init(serial: Int, checkAfterSeconds: Int? = nil, services: [String: Service]) {
        self.schema = Self.schema
        self.version = Self.version
        self.serial = serial
        self.checkAfterSeconds = checkAfterSeconds
        self.services = services
    }
}

public enum ServerService {
    /// Following sites without a feed through the bridge manifest (seam I3).
    public static let bridge = "bridge"
    /// Attested requests. Not used by the app yet.
    public static let attest = "attest"
}

/// Why a server feature is off. Shown in diagnostics; the listener sees "not updating".
public enum ServerFeatureOffReason: Equatable, Sendable {
    /// No config has ever been fetched (first launch offline, or the server never answered).
    case noConfig
    /// The last config the server returned couldn't be used (bad JSON, wrong schema, too large).
    case malformedConfig
    /// The owner switched the feature off, or the config doesn't mention it.
    case switchedOff
    /// No fresh config for longer than the policy allows.
    case staleConfig
    /// The owner switched the feature off for this build.
    case buildTooOld(minimumBuild: Int)
}

public enum ServerFeatureState: Equatable, Sendable {
    case on
    case off(ServerFeatureOffReason)

    public var isOn: Bool { self == .on }
}

/// The config the app holds, with when it was fetched. `malformed` records that the
/// latest answer from the server was unusable, which switches features off even if an
/// older good document is cached.
public struct CachedServerConfig: Codable, Equatable, Sendable {
    public var config: ServerConfig?
    public var fetchedAt: Date
    public var malformed: Bool

    public init(config: ServerConfig?, fetchedAt: Date, malformed: Bool = false) {
        self.config = config
        self.fetchedAt = fetchedAt
        self.malformed = malformed
    }
}

public enum ServerConfigError: Error, Equatable, Sendable {
    case oversized
    case malformed
}

public enum ServerFeatureGate {
    /// A config older than this switches every feature off (DESIGN §4).
    public static let maximumConfigAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumConfigBytes = 16 * 1_024

    /// Parses a config document. Unknown fields are ignored so the server can grow the
    /// format; a different schema or version is refused.
    public static func parse(_ data: Data) throws -> ServerConfig {
        guard data.count <= maximumConfigBytes else { throw ServerConfigError.oversized }
        guard let config = try? JSONDecoder().decode(ServerConfig.self, from: data),
              config.schema == ServerConfig.schema,
              config.version == ServerConfig.version,
              config.serial >= 0 else {
            throw ServerConfigError.malformed
        }
        return config
    }

    /// Whether `service` may be used now. Pure: the store supplies the cache, the clock
    /// and the build.
    public static func state(
        of service: String,
        cached: CachedServerConfig?,
        now: Date,
        appBuild: Int,
        maximumAge: TimeInterval = maximumConfigAge
    ) -> ServerFeatureState {
        guard let cached else { return .off(.noConfig) }
        if cached.malformed { return .off(.malformedConfig) }
        guard let config = cached.config else { return .off(.noConfig) }
        // A fetch time in the future (clock changed) counts as stale rather than fresh forever.
        let age = now.timeIntervalSince(cached.fetchedAt)
        guard age >= -300, age <= maximumAge else { return .off(.staleConfig) }
        guard let entry = config.services[service], entry.enabled else { return .off(.switchedOff) }
        if let minimum = entry.minimumBuild, appBuild < minimum { return .off(.buildTooOld(minimumBuild: minimum)) }
        return .on
    }

    /// What to cache after a fetch returned `data` at `now`. A lower serial than the one
    /// held is ignored outright: the held config stays and doesn't count as refreshed,
    /// so an old document served from a stale cache can't keep a feature alive.
    /// Unusable data marks the cache malformed, which fails closed.
    public static func merge(fetched data: Data, at now: Date, into held: CachedServerConfig?) -> CachedServerConfig {
        guard let config = try? parse(data) else {
            return CachedServerConfig(config: held?.config, fetchedAt: held?.fetchedAt ?? now, malformed: true)
        }
        if let held, let current = held.config, config.serial < current.serial {
            return held
        }
        return CachedServerConfig(config: config, fetchedAt: now)
    }
}
