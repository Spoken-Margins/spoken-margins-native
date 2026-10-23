#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Seam I2, remote half: the app polls a small manifest on the owner's site and
// downloads the catalog only when it is newer, verifying size and SHA-256 as the
// guided onboarding manifest does (GuidedOnboardingCoordinator). Any failure keeps
// what the app already has, so the drawer always works offline from the bundled
// snapshot. Schema: Contracts/schemas/source-catalog-manifest.schema.json.

public struct SourceCatalogManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "source-catalog-manifest.v1"

    public var schemaVersion: String
    public var catalogId: String
    public var contentVersion: Int
    public var generatedAt: String?
    public var catalogURL: String
    public var catalogByteCount: Int
    public var catalogChecksumSHA256: String
    public var entryCount: Int?
}

public struct SourceCatalogPolicy: Equatable, Sendable {
    public static let production = SourceCatalogPolicy(
        manifestURL: ProductServer.url(path: "/onboarding/catalog/v1/manifest.json"),
        trustedHost: ProductServer.host,
        catalogId: "onboarding-top-podcasts"
    )

    public var manifestURL: URL
    public var trustedHost: String
    public var catalogId: String
    public var maximumManifestBytes: Int
    public var maximumCatalogBytes: Int

    public init(manifestURL: URL, trustedHost: String, catalogId: String, maximumManifestBytes: Int = 16 * 1_024, maximumCatalogBytes: Int = 2 * 1_024 * 1_024) {
        self.manifestURL = manifestURL
        self.trustedHost = trustedHost
        self.catalogId = catalogId
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumCatalogBytes = maximumCatalogBytes
    }
}

public enum SourceCatalogError: Error, Equatable, Sendable {
    case untrustedURL
    /// The fetch itself failed (offline, timeout, TLS).
    case network
    case httpStatus(Int)
    case oversizedManifest
    case invalidManifest
    case catalogMismatch
    case oversizedCatalog
    case checksumMismatch
    case invalidCatalog
}

public enum SourceCatalogVerifier {
    public static func manifest(from data: Data, policy: SourceCatalogPolicy) throws -> SourceCatalogManifest {
        guard data.count <= policy.maximumManifestBytes else { throw SourceCatalogError.oversizedManifest }
        guard let manifest = try? JSONDecoder().decode(SourceCatalogManifest.self, from: data),
              manifest.schemaVersion == SourceCatalogManifest.currentSchemaVersion,
              manifest.contentVersion > 0,
              manifest.catalogByteCount > 0,
              manifest.catalogChecksumSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw SourceCatalogError.invalidManifest
        }
        guard manifest.catalogId == policy.catalogId else { throw SourceCatalogError.catalogMismatch }
        guard manifest.catalogByteCount <= policy.maximumCatalogBytes else { throw SourceCatalogError.oversizedCatalog }
        guard let url = URL(string: manifest.catalogURL), isTrusted(url, policy: policy) else { throw SourceCatalogError.untrustedURL }
        return manifest
    }

    /// Verifies a downloaded catalog body against the manifest that pointed to it.
    public static func catalog(from data: Data, manifest: SourceCatalogManifest, policy: SourceCatalogPolicy) throws -> SourceCatalog {
        guard data.count <= policy.maximumCatalogBytes, data.count == manifest.catalogByteCount else {
            throw SourceCatalogError.oversizedCatalog
        }
        guard sha256(data).caseInsensitiveCompare(manifest.catalogChecksumSHA256) == .orderedSame else {
            throw SourceCatalogError.checksumMismatch
        }
        let catalog = try decodeCatalog(data)
        guard catalog.catalogId == manifest.catalogId, catalog.contentVersion == manifest.contentVersion else {
            throw SourceCatalogError.catalogMismatch
        }
        return catalog
    }

    /// Decodes and validates a catalog with no manifest (the bundled snapshot or the cache).
    public static func decodeCatalog(_ data: Data) throws -> SourceCatalog {
        guard let decoded = try? JSONDecoder().decode(SourceCatalog.self, from: data),
              let catalog = try? SourceCatalogValidator.validated(decoded) else {
            throw SourceCatalogError.invalidCatalog
        }
        return catalog
    }

    public static func isTrusted(_ url: URL, policy: SourceCatalogPolicy) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == policy.trustedHost.lowercased()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SourceCatalogRefreshOutcome: Equatable, Sendable {
    /// A newer catalog was downloaded, verified and cached.
    case updated(contentVersion: Int)
    /// The remote catalog is not newer than what the app holds.
    case unchanged(contentVersion: Int)
    /// Refresh failed; the app keeps the catalog it had.
    case failed(SourceCatalogError)
}

/// The app implements this with URLSession (no URL cache, bounded redirects); tests pass recorded responses.
public typealias SourceCatalogFetch = SourceHTTPFetch

public actor SourceCatalogStore {
    private let bundledCatalogURL: URL
    private let cacheDirectory: URL
    private let policy: SourceCatalogPolicy
    private let fetch: SourceCatalogFetch
    private let fileManager: FileManager
    private var loaded: SourceCatalog?

    public init(bundledCatalogURL: URL, cacheDirectory: URL, policy: SourceCatalogPolicy = .production, fileManager: FileManager = .default, fetch: @escaping SourceCatalogFetch) {
        self.bundledCatalogURL = bundledCatalogURL
        self.cacheDirectory = cacheDirectory
        self.policy = policy
        self.fileManager = fileManager
        self.fetch = fetch
    }

    private var cachedCatalogURL: URL { cacheDirectory.appendingPathComponent("\(policy.catalogId).json") }

    /// The newest valid catalog among the cache and the bundled snapshot. Works offline.
    /// Throws only if the bundled snapshot itself is missing or invalid (a build error).
    public func current() throws -> SourceCatalog {
        if let loaded { return loaded }
        let bundled = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: bundledCatalogURL))
        var best = bundled
        if let data = try? Data(contentsOf: cachedCatalogURL),
           let cached = try? SourceCatalogVerifier.decodeCatalog(data),
           cached.catalogId == bundled.catalogId,
           cached.contentVersion > bundled.contentVersion {
            best = cached
        }
        loaded = best
        return best
    }

    /// Checks the remote manifest and takes a newer catalog if there is one. Never throws:
    /// on any failure the current catalog stays in place.
    @discardableResult
    public func refresh() async -> SourceCatalogRefreshOutcome {
        let held: SourceCatalog
        do { held = try current() } catch { return .failed(.invalidCatalog) }
        do {
            guard SourceCatalogVerifier.isTrusted(policy.manifestURL, policy: policy) else { throw SourceCatalogError.untrustedURL }
            let manifestResponse = try await fetchBody(policy.manifestURL, maximumBytes: policy.maximumManifestBytes)
            let manifest = try SourceCatalogVerifier.manifest(from: manifestResponse, policy: policy)
            guard manifest.contentVersion > held.contentVersion else {
                return .unchanged(contentVersion: held.contentVersion)
            }
            guard let catalogURL = URL(string: manifest.catalogURL) else { throw SourceCatalogError.untrustedURL }
            let body = try await fetchBody(catalogURL, maximumBytes: manifest.catalogByteCount)
            let catalog = try SourceCatalogVerifier.catalog(from: body, manifest: manifest, policy: policy)
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try body.write(to: cachedCatalogURL, options: .atomic)
            loaded = catalog
            return .updated(contentVersion: catalog.contentVersion)
        } catch let error as SourceCatalogError {
            return .failed(error)
        } catch {
            return .failed(.network)
        }
    }

    private func fetchBody(_ url: URL, maximumBytes: Int) async throws -> Data {
        let (status, body) = try await fetch(url, maximumBytes)
        guard (200..<300).contains(status) else { throw SourceCatalogError.httpStatus(status) }
        return body
    }
}
