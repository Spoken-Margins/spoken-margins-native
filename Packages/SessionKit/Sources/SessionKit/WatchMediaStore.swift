import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Sent with a media file, phone to Watch (#789).
public struct WatchMediaTransferManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var identity: WatchMediaIdentity
    public var fileExtension: String
    public var byteCount: Int
    public var sha256: String
    public var durationMs: Int

    public init(
        schemaVersion: String = "watch-media-transfer.v1",
        identity: WatchMediaIdentity,
        fileExtension: String,
        byteCount: Int,
        sha256: String,
        durationMs: Int
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMs = durationMs
    }
}

/// Watch to phone: what happened to a media transfer.
public struct WatchMediaInstallAcknowledgement: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case installed
        /// The same bytes were already installed; nothing changed.
        case alreadyInstalled
        /// Fewer or more bytes than the manifest: the transfer was cut short.
        case incomplete
        case checksumMismatch
        /// Different bytes for media already installed, while Margins recorded against the
        /// installed bytes haven't reached the phone. Nothing changed; send it again later, or
        /// send the new bytes as a new revision.
        case heldForUnsyncedMargins
    }

    public var identity: WatchMediaIdentity
    public var sha256: String
    public var status: Status

    public init(identity: WatchMediaIdentity, sha256: String, status: Status) {
        self.identity = identity
        self.sha256 = sha256
        self.status = status
    }

    public var confirmsInstall: Bool { status == .installed || status == .alreadyInstalled }
}

/// Answers whether Margins recorded on the Watch against some media haven't reached the phone.
/// The Watch's Margin outbox (#788) provides it; media holding such Margins is never removed.
public protocol WatchUnsyncedMarginChecking {
    func hasUnsyncedMargins(itemId: String, sourceRevision: String) -> Bool
}

public enum WatchMediaStoreError: Error, Equatable {
    case invalidFileExtension(String)
    case notInstalled
    /// Margins recorded against this media haven't reached the phone yet.
    case unsyncedMargins
}

/// The Watch's installed media (#789).
///
/// A transfer is checked against its manifest, staged, flushed and renamed into place, so after
/// an interrupted transfer, a crash or power loss, media is either fully installed or not at all,
/// and only fully installed media reports a duration. Installing the same bytes again changes
/// nothing. A new revision replaces the old one only when no unsynced Margin needs the old one.
public final class WatchMediaStore {
    static let recordFileName = "install.json"
    static let abandonedStagingAge: TimeInterval = 60

    public let directory: URL
    private let unsyncedMargins: WatchUnsyncedMarginChecking
    private var installs: [String: WatchMediaInstall]

    public init(directory: URL, unsyncedMargins: WatchUnsyncedMarginChecking, now: Date = Date()) throws {
        self.directory = directory
        self.unsyncedMargins = unsyncedMargins
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [String: WatchMediaInstall] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix(".staging-") {
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                if modified.map({ now.timeIntervalSince($0) >= Self.abandonedStagingAge }) ?? true {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard !name.hasPrefix("."),
                  let data = try? Data(contentsOf: url.appendingPathComponent(Self.recordFileName)),
                  let install = try? JSONDecoder().decode(WatchMediaInstall.self, from: data),
                  Self.folderName(install) == name else { continue }
            let key = Self.key(install.identity)
            // A stop between installing new bytes and removing the old leaves both: keep the newer.
            if let other = loaded[key] {
                let otherIsNewer = (other.installedAt, Self.folderName(other)) > (install.installedAt, Self.folderName(install))
                let (keep, drop) = otherIsNewer ? (other, install) : (install, other)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.folderName(drop)))
                loaded[key] = keep
            } else {
                loaded[key] = install
            }
        }
        installs = loaded
    }

    /// Everything installed for an item, newest first.
    public func installs(itemId: String) -> [WatchMediaInstall] {
        installs.values.filter { $0.identity.itemId == itemId }.sorted { $0.installedAt > $1.installedAt }
    }

    public func fileURL(for install: WatchMediaInstall) -> URL {
        directory.appendingPathComponent(Self.folderName(install)).appendingPathComponent(install.fileName)
    }

    /// Checks and installs a received file. The acknowledgement goes back to the phone.
    public func install(file: URL, manifest: WatchMediaTransferManifest, now: Date) throws -> WatchMediaInstallAcknowledgement {
        guard !manifest.fileExtension.isEmpty, manifest.fileExtension.count <= 8,
              manifest.fileExtension.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw WatchMediaStoreError.invalidFileExtension(manifest.fileExtension)
        }
        let key = Self.key(manifest.identity)
        if let existing = installs[key], existing.sha256 == manifest.sha256 {
            return WatchMediaInstallAcknowledgement(identity: manifest.identity, sha256: existing.sha256, status: .alreadyInstalled)
        }
        // Episodes run to tens of megabytes, so hash in chunks rather than loading the file.
        let (byteCount, sha256) = try Self.digest(of: file)
        guard byteCount == manifest.byteCount else {
            return WatchMediaInstallAcknowledgement(identity: manifest.identity, sha256: sha256, status: .incomplete)
        }
        guard sha256 == manifest.sha256 else {
            return WatchMediaInstallAcknowledgement(identity: manifest.identity, sha256: sha256, status: .checksumMismatch)
        }
        if installs[key] != nil,
           unsyncedMargins.hasUnsyncedMargins(itemId: manifest.identity.itemId, sourceRevision: manifest.identity.sourceRevision) {
            // Unsynced Margins point into the installed bytes; swapping them would move their audio.
            return WatchMediaInstallAcknowledgement(identity: manifest.identity, sha256: sha256, status: .heldForUnsyncedMargins)
        }

        let install = WatchMediaInstall(
            identity: manifest.identity,
            fileName: "media.\(manifest.fileExtension)",
            byteCount: byteCount,
            sha256: sha256,
            durationMs: manifest.durationMs,
            installedAt: now
        )
        let staging = directory.appendingPathComponent(".staging-\(key)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let mediaFile = staging.appendingPathComponent(install.fileName)
            let recordFile = staging.appendingPathComponent(Self.recordFileName)
            try FileManager.default.copyItem(at: file, to: mediaFile)
            try JSONEncoder().encode(install).write(to: recordFile)
            try Self.flush(mediaFile)
            try Self.flush(recordFile)
            try Self.flush(staging)
            // Each set of bytes gets its own folder, so new bytes for the same identity land beside
            // the old ones and there is never a moment with no complete media.
            try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(Self.folderName(install), isDirectory: true))
            try Self.flush(directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        if let previous = installs[key] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.folderName(previous)))
        }
        installs[key] = install
        removeReplacedRevisions(of: install)
        return WatchMediaInstallAcknowledgement(identity: manifest.identity, sha256: sha256, status: .installed)
    }

    /// Removes installed media to make room. Refused while unsynced Margins need it.
    public func evict(_ identity: WatchMediaIdentity) throws {
        let key = Self.key(identity)
        guard let install = installs[key] else { throw WatchMediaStoreError.notInstalled }
        guard !unsyncedMargins.hasUnsyncedMargins(itemId: identity.itemId, sourceRevision: identity.sourceRevision) else {
            throw WatchMediaStoreError.unsyncedMargins
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(Self.folderName(install)))
        installs.removeValue(forKey: key)
    }

    /// Older revisions of the same media go once the new one is installed, unless unsynced Margins
    /// still point into them. Those stay until a later install or eviction finds them synced.
    private func removeReplacedRevisions(of install: WatchMediaInstall) {
        for (key, old) in installs where old.identity != install.identity && old.identity.sameMedia(as: install.identity) {
            guard !unsyncedMargins.hasUnsyncedMargins(itemId: old.identity.itemId, sourceRevision: old.identity.sourceRevision) else { continue }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.folderName(old)))) != nil {
                installs.removeValue(forKey: key)
            }
        }
    }

    /// The folder holding one set of bytes for one identity.
    static func folderName(_ install: WatchMediaInstall) -> String {
        "\(key(install.identity))-\(install.sha256.prefix(16))"
    }

    /// Names an identity on disk: its parts can hold any characters, so the name is a digest.
    static func key(_ identity: WatchMediaIdentity) -> String {
        let text = [identity.itemId, identity.sourceRevision, identity.kind.rawValue, identity.mediaId].joined(separator: "\u{1F}")
        return String(hex(SHA256.hash(data: Data(text.utf8))).prefix(32))
    }

    static func digest(of file: URL) throws -> (byteCount: Int, sha256: String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += chunk.count
        }
        return (byteCount, hex(hasher.finalize()))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}

/// The phone's record of what the Watch has installed (#789).
///
/// Only an acknowledgement for the exact bytes the phone sent marks media installed, so a late
/// or repeated acknowledgement for an earlier transfer or revision can't make incomplete media
/// look installed.
public struct WatchMediaDeliveryLedger: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case sent
        case installed
        case needsResend
    }

    public private(set) var sent: [WatchMediaIdentity: String] = [:]
    public private(set) var states: [WatchMediaIdentity: State] = [:]

    public init() {}

    /// The phone handed this manifest's file to WatchConnectivity.
    public mutating func recordSent(_ manifest: WatchMediaTransferManifest) {
        sent[manifest.identity] = manifest.sha256
        states[manifest.identity] = .sent
    }

    @discardableResult
    public mutating func apply(_ acknowledgement: WatchMediaInstallAcknowledgement) -> State? {
        guard let expected = sent[acknowledgement.identity] else { return nil }
        if acknowledgement.confirmsInstall {
            // Installed bytes must be the bytes sent.
            if acknowledgement.sha256 == expected { states[acknowledgement.identity] = .installed }
        } else if states[acknowledgement.identity] != .installed {
            // A failed attempt arriving after a later success changes nothing.
            states[acknowledgement.identity] = .needsResend
        }
        return states[acknowledgement.identity]
    }

    public func isInstalled(_ identity: WatchMediaIdentity) -> Bool {
        states[identity] == .installed
    }
}
