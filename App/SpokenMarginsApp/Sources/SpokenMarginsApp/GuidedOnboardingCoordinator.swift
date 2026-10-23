import CryptoKit
import Foundation
import SessionKit

struct GuidedOnboardingPayload: Sendable {
    var manifest: GuidedOnboardingManifest
    var audioURL: URL
    var audioChanged: Bool
}

enum GuidedOnboardingError: Error, LocalizedError {
    case invalidEndpoint
    case oversizedManifest
    case invalidManifest
    case oversizedAudio
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The guided tour endpoint is not trusted."
        case .oversizedManifest: "The guided tour manifest is too large."
        case .invalidManifest: "The guided tour manifest is invalid."
        case .oversizedAudio: "The guided tour audio is too large."
        case .checksumMismatch: "The guided tour audio checksum does not match."
        }
    }
}

actor GuidedOnboardingCoordinator {
    static let productionManifestURL = ProductServer.url(path: "/onboarding/v1/manifest.json")
    private static let expectedHost = ProductServer.host
    private static let maximumManifestBytes = 128 * 1_024
    private static let maximumAudioBytes: Int64 = 64 * 1_024 * 1_024

    private let manifestURL: URL
    private let session: URLSession
    private let directory: URL
    private let ledger: OfflineStorageLedger
    private let fileManager: FileManager

    init(manifestURL: URL = productionManifestURL, session: URLSession = .shared, directory: URL, ledger: OfflineStorageLedger, fileManager: FileManager = .default) {
        self.manifestURL = manifestURL
        self.session = session
        self.directory = directory
        self.ledger = ledger
        self.fileManager = fileManager
    }

    func refresh() async throws -> GuidedOnboardingPayload {
        try validate(url: manifestURL)
        do {
            let (data, response) = try await session.data(from: manifestURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GuidedOnboardingError.invalidManifest
            }
            guard data.count <= Self.maximumManifestBytes else { throw GuidedOnboardingError.oversizedManifest }
            let manifest = try JSONDecoder().decode(GuidedOnboardingManifest.self, from: data)
            try validate(manifest: manifest)
            let payload = try await downloadAudio(for: manifest)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cachedManifestURL, options: .atomic)
            return payload
        } catch {
            if let cached = try? loadCached() { return cached }
            throw error
        }
    }

    private func downloadAudio(for manifest: GuidedOnboardingManifest) async throws -> GuidedOnboardingPayload {
        guard let remote = URL(string: manifest.audioURL) else { throw GuidedOnboardingError.invalidManifest }
        try validate(url: remote)
        var head = URLRequest(url: remote)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: head)
        guard let http = headResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let rawLength = http.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(rawLength),
              length > 0,
              length <= Self.maximumAudioBytes else { throw GuidedOnboardingError.oversizedAudio }
        let reservation = try await ledger.reserve(ownerId: "guided-onboarding-audio", byteCount: length)
        do {
            let (data, response) = try await session.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  Int64(data.count) == length else { throw GuidedOnboardingError.invalidManifest }
            let checksum = Self.sha256(data)
            guard checksum.caseInsensitiveCompare(manifest.audioChecksumSHA256) == .orderedSame else {
                throw GuidedOnboardingError.checksumMismatch
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "guided-onboarding-\(manifest.contentVersion).m4a")
            try data.write(to: destination, options: .atomic)
            let previous = try? loadCachedManifest()
            try await ledger.commit(
                reservationId: reservation.id,
                asset: OwnedOfflineAsset(
                    id: "guided-onboarding-audio",
                    itemId: manifest.itemId,
                    category: .guidedTour,
                    relativePath: "GuidedOnboarding/\(destination.lastPathComponent)",
                    byteCount: length,
                    checksumSHA256: checksum,
                    isReproducible: true
                )
            )
            return GuidedOnboardingPayload(
                manifest: manifest,
                audioURL: destination,
                audioChanged: previous?.audioChecksumSHA256 != manifest.audioChecksumSHA256
            )
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    private func loadCached() throws -> GuidedOnboardingPayload {
        let manifest = try loadCachedManifest()
        let audio = directory.appending(path: "guided-onboarding-\(manifest.contentVersion).m4a")
        guard fileManager.fileExists(atPath: audio.path),
              Self.sha256(try Data(contentsOf: audio, options: [.mappedIfSafe])) == manifest.audioChecksumSHA256.lowercased() else {
            throw GuidedOnboardingError.invalidManifest
        }
        return GuidedOnboardingPayload(manifest: manifest, audioURL: audio, audioChanged: false)
    }

    private func loadCachedManifest() throws -> GuidedOnboardingManifest {
        try JSONDecoder().decode(GuidedOnboardingManifest.self, from: Data(contentsOf: cachedManifestURL))
    }

    private var cachedManifestURL: URL { directory.appending(path: "manifest.json") }

    private func validate(url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == Self.expectedHost else {
            throw GuidedOnboardingError.invalidEndpoint
        }
    }

    private func validate(manifest: GuidedOnboardingManifest) throws {
        guard manifest.schemaVersion == "guided-onboarding.v1",
              manifest.itemId == "guided-onboarding",
              manifest.contentVersion > 0,
              (1...160).contains(manifest.title.count),
              manifest.description.count <= 2_000,
              manifest.actions.count <= 12,
              Set(manifest.actions.map(\.id)).count == manifest.actions.count,
              manifest.audioChecksumSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw GuidedOnboardingError.invalidManifest
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
