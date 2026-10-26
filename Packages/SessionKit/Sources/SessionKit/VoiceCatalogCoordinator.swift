import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Settings › Voices (#1819, the app side of #1392): which voices a listener can download, whether they
// agreed to a voice's licence, and installing or removing one through VoiceModelInstaller (#1817).
//
// The catalog is fetched only when the listener opens Settings › Voices or starts a download, never at
// launch. The last catalog that verified is kept; with none, the snapshot bundled with the app stands in
// (it is code-signed with the app, so it needs no catalog signature). Everything here is host-testable;
// the app supplies the transport (a background URLSession) and the screen.

/// Fetches the signed catalog envelope. A protocol so tests can serve one from memory.
public protocol VoiceCatalogFetching: Sendable {
    func fetchEnvelope(from url: URL) async throws -> Data
}

/// A plain GET with no identifier, cookie or query string: the same request from every listener.
public struct URLSessionVoiceCatalogFetcher: VoiceCatalogFetching {
    public init() {}

    public func fetchEnvelope(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= VoiceModelCatalogVerifier.maximumEnvelopeBytes else { throw VoiceCatalogError.oversized }
        return data
    }
}

/// The listener agreed to one licence text. Kept on the device only.
public struct VoiceLicenseAgreement: Codable, Equatable, Sendable {
    public var licenseId: String
    /// The reviewed text's SHA-256 at the time. A changed licence text needs a new agreement.
    public var textSHA256: String
    public var agreedAt: Date

    public init(licenseId: String, textSHA256: String, agreedAt: Date) {
        self.licenseId = licenseId
        self.textSHA256 = textSHA256
        self.agreedAt = agreedAt
    }
}

/// Where the voices on offer came from.
public enum VoiceCatalogSource: Equatable, Sendable {
    /// A signed catalog that verified, now or on an earlier visit.
    case verified(catalogVersion: Int)
    /// The snapshot that shipped with the app: no signed catalog has verified on this device yet.
    case bundledSnapshot
    /// Neither: nothing can be offered.
    case none
}

/// What a voice is on this device.
public enum VoiceCatalogRowState: Equatable, Sendable {
    /// Ships inside the app (Kitten): nothing to download, nothing to remove.
    case bundled
    case notInstalled
    /// `version` is the installed folder's name; `byteCount` what it takes on disk.
    case installed(version: String, byteCount: Int64)
}

public struct VoiceCatalogRow: Equatable, Sendable, Identifiable {
    public var entry: VoiceModelEntry
    public var state: VoiceCatalogRowState
    /// Licences with use restrictions the listener hasn't agreed to in their current wording.
    public var licensesNeedingAgreement: [VoiceModelLicense]
    /// False for a withdrawn or superseded voice: an installed copy keeps working and can be removed,
    /// but it can't be downloaded again. Also false on a device below the voice's chip floor or memory need.
    public var isOffered: Bool
    /// Why this device can't use the voice at all, whatever the catalog says: nil when it can. An installed copy
    /// that this reason applies to never reads here (a backup restored to an older phone, say).
    public var unusableHere: VoiceUnusableReason?

    public init(
        entry: VoiceModelEntry,
        state: VoiceCatalogRowState,
        licensesNeedingAgreement: [VoiceModelLicense],
        isOffered: Bool,
        unusableHere: VoiceUnusableReason? = nil
    ) {
        self.entry = entry
        self.state = state
        self.licensesNeedingAgreement = licensesNeedingAgreement
        self.isOffered = isOffered
        self.unusableHere = unusableHere
    }

    public var id: String { entry.id }

    /// What Settings › Voices says beside Remove for an installed voice that can't be downloaded now, or nil.
    /// A copy below the device's floor is not told it "keeps working": it doesn't, Kitten reads (#2735 review).
    public var installedButNotOfferedNote: String? {
        guard case .installed = state, !isOffered else { return nil }
        switch unusableHere {
        case .chipBelowFloor:
            return "This phone is older than this voice needs, so Kitten reads instead. Remove frees the space."
        case .notEnoughMemory:
            return "This phone has less memory than this voice needs, so Kitten reads instead. Remove frees the space."
        case nil:
            return "No longer offered. This copy keeps working."
        }
    }
}

/// Why a device can't use a catalog voice (#2700).
public enum VoiceUnusableReason: Equatable, Sendable {
    /// The device's chip is older than the entry's `minimumChip`, or can't be told.
    case chipBelowFloor
    case notEnoughMemory
}

public enum VoiceCatalogCoordinatorError: Error, Equatable, LocalizedError {
    case voiceNotOffered(String)
    case agreementNeeded(licenseIds: [String])
    case install(VoiceModelInstallError)

    public var errorDescription: String? {
        switch self {
        case .voiceNotOffered: "This voice is no longer offered for download."
        case .agreementNeeded: "Agree to the voice's licence before it downloads."
        case .install(let error): VoiceCatalogCoordinator.plainWords(for: error)
        }
    }
}

public actor VoiceCatalogCoordinator {
    public struct Configuration: Sendable {
        /// Where the signed catalog is fetched from. Nil: no fetch, and the bundled snapshot (or a catalog
        /// already kept) is all there is.
        public var catalogURL: URL?
        public var trustedKeys: [VoiceCatalogTrustedKey]
        /// Voice ids this build has an engine for. Anything else in the catalog isn't shown.
        public var playableVoiceIds: Set<String>
        /// The device's memory as iOS reports it, for each voice's `minimumMemoryMegabytes`. Compared after
        /// rounding to the size on the box (`nominalMemoryMegabytes`).
        public var physicalMemoryMegabytes: Int
        /// The device's chip as an A-series generation (`VoiceDeviceFloor.generation(ofMachine:)`), for each
        /// voice's `minimumChip`. Nil when unknown: voices with a floor are then not offered.
        public var deviceChipGeneration: Int?
        /// The one-time preparation each runtime needs after download (#2700).
        public var preparers: VoiceModelPreparers
        /// The catalog document (unsigned payload) bundled with the app, used until a signed one verifies.
        public var bundledSnapshot: Data?

        public init(
            catalogURL: URL?,
            trustedKeys: [VoiceCatalogTrustedKey] = VoiceCatalogTrust.production,
            playableVoiceIds: Set<String>,
            physicalMemoryMegabytes: Int = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            deviceChipGeneration: Int? = nil,
            preparers: VoiceModelPreparers = .standard,
            bundledSnapshot: Data? = nil
        ) {
            self.catalogURL = catalogURL
            self.trustedKeys = trustedKeys
            self.playableVoiceIds = playableVoiceIds
            self.physicalMemoryMegabytes = physicalMemoryMegabytes
            self.deviceChipGeneration = deviceChipGeneration
            self.preparers = preparers
            self.bundledSnapshot = bundledSnapshot
        }
    }

    /// Under Application Support. The ledger's root is Application Support, so rows name `Voices/<id>`.
    public static let voicesFolderName = "Voices"
    /// The cached envelope and the listener's agreements, also under Application Support.
    public static let stateFolderName = "VoiceCatalog"
    /// Ledger row ids for installed voices start with this, which is how Storage labels them.
    public static let ledgerAssetPrefix = "voice-model-"
    /// No new `OfflineAssetCategory` value: Build 29 decodes that enum strictly (#1819 point 4).
    public static let ledgerCategory: OfflineAssetCategory = .sourceDocument

    private let supportDirectory: URL
    private let configuration: Configuration
    private let fetcher: VoiceCatalogFetching
    private let installer: VoiceModelInstaller
    /// What the catalog and the installer did, for Diagnostics (#2224).
    public nonisolated let log: VoiceDownloadLog
    private let repository: (any OfflineStorageRepository & Sendable)?
    private let now: @Sendable () -> Date
    private var catalog: VerifiedVoiceModelCatalog?
    private var source: VoiceCatalogSource = .none
    private var loaded = false

    public init(
        supportDirectory: URL,
        configuration: Configuration,
        fetcher: VoiceCatalogFetching = URLSessionVoiceCatalogFetcher(),
        transport: VoiceModelTransport = URLSessionVoiceModelTransport(),
        installerConfiguration: VoiceModelInstaller.Configuration = VoiceModelInstaller.Configuration(),
        repository: (any OfflineStorageRepository & Sendable)?,
        log: VoiceDownloadLog? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.supportDirectory = supportDirectory
        self.configuration = configuration
        self.fetcher = fetcher
        let log = log ?? VoiceDownloadLog(fileURL: Self.downloadLogURL(supportDirectory: supportDirectory))
        self.log = log
        var installerConfiguration = installerConfiguration
        if installerConfiguration.log == nil { installerConfiguration.log = log }
        self.installer = VoiceModelInstaller(
            root: Self.voicesRoot(supportDirectory: supportDirectory),
            transport: transport,
            configuration: installerConfiguration
        )
        self.repository = repository
        self.now = now
    }

    // MARK: Where things live

    /// The memory size on the box, from what iOS reports (#2055 audit 3). iOS reserves part of the RAM, so a
    /// "4 GB" iPhone 12 reports about 3,700 MB and would fail a 4,096 MB minimum. Rounds to the nearest GB.
    public static func nominalMemoryMegabytes(reported megabytes: Int) -> Int {
        max(0, (megabytes + 512) / 1_024) * 1_024
    }

    public static func voicesRoot(supportDirectory: URL) -> URL {
        supportDirectory.appending(path: voicesFolderName, directoryHint: .isDirectory)
    }

    /// The installed folder of a voice, whatever version, or nil. Nonisolated and cheap, so playback can
    /// ask without waiting on a download in progress.
    public static func installedFolder(voiceId: String, supportDirectory: URL) -> URL? {
        let installer = VoiceModelInstaller(root: voicesRoot(supportDirectory: supportDirectory))
        guard let version = installer.installedVersions(voiceId: voiceId).last else { return nil }
        return installer.installedFolder(voiceId: voiceId, version: version)
    }

    /// Where the download log is kept, for the Diagnostics export to read without a coordinator.
    public static func downloadLogURL(supportDirectory: URL) -> URL {
        VoiceDownloadLog.fileURL(stateFolder: supportDirectory.appending(path: stateFolderName, directoryHint: .isDirectory))
    }

    private var stateFolder: URL { supportDirectory.appending(path: Self.stateFolderName, directoryHint: .isDirectory) }
    private var cachedEnvelopeURL: URL { stateFolder.appending(path: "catalog.json") }
    private var agreementsURL: URL { stateFolder.appending(path: "agreements.json") }

    // MARK: The catalog

    public var catalogSource: VoiceCatalogSource {
        loadIfNeeded()
        return source
    }

    /// The rows from what is already on the device (cached catalog or bundled snapshot). No network.
    public func rows() -> [VoiceCatalogRow] {
        loadIfNeeded()
        let agreements = loadAgreements()
        let entries = (catalog?.voices ?? []).filter { configuration.playableVoiceIds.contains($0.id) || $0.bundled }
        return entries.compactMap { entry in
            let state = state(of: entry)
            let unusable = VoiceDeviceFit.floorFailure(
                entry, deviceGeneration: configuration.deviceChipGeneration,
                physicalMemoryMegabytes: configuration.physicalMemoryMegabytes
            )
            let offered = entry.status == .available && unusable == nil
            // A voice that isn't offered and isn't here has nothing to show.
            if !offered, state == .notInstalled { return nil }
            return VoiceCatalogRow(
                entry: entry,
                state: state,
                licensesNeedingAgreement: entry.licensesRequiringAcceptance.filter { license in
                    !agreements.contains { $0.licenseId == license.id && $0.textSHA256 == license.textSHA256 }
                },
                isOffered: offered,
                unusableHere: VoiceDeviceFit.renderBlocker(
                    entry, deviceGeneration: configuration.deviceChipGeneration,
                    physicalMemoryMegabytes: configuration.physicalMemoryMegabytes
                )
            )
        }
    }

    /// Fetches the signed catalog and keeps it if it verifies. A failure leaves the last good catalog in
    /// place and is returned for diagnostics; the listener still sees what was there.
    @discardableResult
    public func refresh() async -> VoiceCatalogError? {
        loadIfNeeded()
        guard let catalogURL = configuration.catalogURL else {
            log.record("catalog.fetch_skipped", ["reason": "no catalog address", "source": sourceName])
            return nil
        }
        log.record("catalog.fetch", ["host": VoiceDownloadLog.host(of: catalogURL.absoluteString)])
        let data: Data
        do {
            data = try await fetcher.fetchEnvelope(from: catalogURL)
        } catch let error as VoiceCatalogError {
            log.record("catalog.fetch_failed", ["reason": Self.reason(for: error), "source": sourceName])
            return error
        } catch {
            log.record("catalog.fetch_failed", ["reason": Self.fetchFailureReason(error), "source": sourceName])
            return .malformedEnvelope
        }
        log.record("catalog.fetched", ["bytes": String(data.count)])
        let lastAccepted: Int? = if case .verified(let version) = source { version } else { nil }
        do {
            let verified = try VoiceModelCatalogVerifier.verify(
                envelopeData: data,
                trustedKeys: configuration.trustedKeys,
                lastAcceptedCatalogVersion: lastAccepted
            )
            catalog = verified
            source = .verified(catalogVersion: verified.catalogVersion)
            try? createStateFolder()
            try? data.write(to: cachedEnvelopeURL, options: .atomic)
            log.record("catalog.signature_verified", [
                "keyId": verified.keyId, "catalogVersion": String(verified.catalogVersion), "voices": String(verified.voices.count)
            ])
            return nil
        } catch let error as VoiceCatalogError {
            log.record("catalog.signature_rejected", ["reason": Self.reason(for: error), "kept": sourceName])
            return error
        } catch {
            log.record("catalog.signature_rejected", ["reason": "malformed", "kept": sourceName])
            return .malformedEnvelope
        }
    }

    /// Which catalog stands, in the words the log uses.
    private var sourceName: String {
        switch source {
        case .verified(let version): "signed catalog \(version)"
        case .bundledSnapshot: "bundled snapshot"
        case .none: "none"
        }
    }

    static func reason(for error: VoiceCatalogError) -> String {
        switch error {
        case .oversized: "too large"
        case .malformedEnvelope: "malformed envelope"
        case .unsupportedEnvelopeVersion(let version): "unsupported envelope version \(version)"
        case .unsupportedAlgorithm(let name): "unsupported algorithm \(name)"
        case .unknownKey(let keyId): "unknown key \(keyId)"
        case .badSignature: "bad signature"
        case .malformedPayload: "malformed payload"
        case .unsupportedSchemaVersion(let version): "unsupported schema version \(version)"
        case .invalidCatalogVersion: "invalid catalog version"
        case .invalidIssuedAt: "invalid issue date"
        case .rollback(let last, let offered): "rollback: offered \(offered), already accepted \(last)"
        case .duplicateVoiceID(let id): "duplicate voice id \(id)"
        }
    }

    private static func fetchFailureReason(_ error: Error) -> String {
        if let urlError = error as? URLError { return "network error \(urlError.code.rawValue)" }
        return "fetch failed"
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cachedEnvelopeURL) {
            do {
                let verified = try VoiceModelCatalogVerifier.verify(envelopeData: data, trustedKeys: configuration.trustedKeys)
                catalog = verified
                source = .verified(catalogVersion: verified.catalogVersion)
                log.record("catalog.loaded", [
                    "source": "signed catalog kept", "keyId": verified.keyId,
                    "catalogVersion": String(verified.catalogVersion), "voices": String(verified.voices.count)
                ])
                return
            } catch {
                let reason = (error as? VoiceCatalogError).map(Self.reason(for:)) ?? "unreadable"
                log.record("catalog.kept_rejected", ["reason": reason])
            }
        }
        if let snapshot = configuration.bundledSnapshot,
           let decoded = try? VoiceModelCatalog.decode(snapshot),
           let screened = try? VoiceModelCatalogVerifier.screen(decoded) {
            catalog = screened
            source = .bundledSnapshot
            log.record("catalog.loaded", ["source": "bundled snapshot", "voices": String(screened.voices.count)])
        } else {
            log.record("catalog.loaded", ["source": "none", "bundledSnapshot": configuration.bundledSnapshot == nil ? "missing" : "unreadable"])
        }
    }

    private func state(of entry: VoiceModelEntry) -> VoiceCatalogRowState {
        if entry.bundled { return .bundled }
        guard let version = installer.installedVersions(voiceId: entry.id).last,
              let folder = installer.installedFolder(voiceId: entry.id, version: version) else { return .notInstalled }
        return .installed(version: version, byteCount: Self.byteCount(of: folder))
    }

    // MARK: Agreements

    /// Records that the listener agreed to these licences in their current wording.
    public func agree(to licenses: [VoiceModelLicense]) throws {
        var agreements = loadAgreements().filter { existing in !licenses.contains { $0.id == existing.licenseId } }
        let moment = now()
        agreements += licenses.map { VoiceLicenseAgreement(licenseId: $0.id, textSHA256: $0.textSHA256, agreedAt: moment) }
        try createStateFolder()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(agreements).write(to: agreementsURL, options: .atomic)
    }

    public func agreements() -> [VoiceLicenseAgreement] { loadAgreements() }

    private func loadAgreements() -> [VoiceLicenseAgreement] {
        guard let data = try? Data(contentsOf: agreementsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VoiceLicenseAgreement].self, from: data)) ?? []
    }

    /// Kept out of iCloud and device backups: the agreement stays on this device (#1819 point 2).
    private func createStateFolder() throws {
        try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = stateFolder
        try? folder.setResourceValues(values)
    }

    // MARK: Install and remove

    /// Downloads and installs a voice, then records it in the Storage ledger. Refuses before any byte moves
    /// when the voice isn't offered or a licence still needs agreeing. Cancelling the task keeps what has
    /// downloaded, so a later call resumes.
    @discardableResult
    public func install(
        voiceId: String,
        progress: (@Sendable (VoiceModelInstallProgress) -> Void)? = nil
    ) async throws -> URL {
        guard let row = rows().first(where: { $0.id == voiceId }), row.isOffered, !row.entry.bundled else {
            log.record("install.refused", ["voice": voiceId, "reason": "not offered", "source": sourceName])
            throw VoiceCatalogCoordinatorError.voiceNotOffered(voiceId)
        }
        guard row.licensesNeedingAgreement.isEmpty else {
            log.record("install.refused", ["voice": voiceId, "reason": "licence not agreed", "licenses": row.licensesNeedingAgreement.map(\.id).joined(separator: ",")])
            throw VoiceCatalogCoordinatorError.agreementNeeded(licenseIds: row.licensesNeedingAgreement.map(\.id))
        }
        log.record("install.started", [
            "voice": voiceId, "version": row.entry.version, "bytesToDownload": String(row.entry.downloadByteCount)
        ])
        // The entry's own mapping carries every way a file arrives: downloaded, written from text the
        // catalog carries, or taken from an archive. Rebuilding it here from `sources` alone dropped the
        // last two, and Supertonic's notices have no source, so every install failed (#2055 audit).
        let preparer = configuration.preparers.preparer(forRuntime: row.entry.runtime.name)
        let entry = row.entry
        let prepare: (@Sendable (URL) async throws -> Void)? = preparer.needsPreparation
            ? { @Sendable folder in try await preparer.prepare(stagedFolder: folder, entry: entry) }
            : nil
        let folder: URL
        do {
            folder = try await installer.install(
                voiceId: voiceId,
                version: Self.folderName(forVersion: row.entry.version),
                files: row.entry.installFiles,
                archives: row.entry.installArchives,
                progress: progress,
                prepare: prepare,
                preparationBytes: preparer.needsPreparation ? preparer.extraBytes(for: entry) : 0
            )
        } catch is CancellationError {
            log.record("install.cancelled", ["voice": voiceId])
            throw CancellationError()
        } catch let error as VoiceModelInstallError {
            log.record("install.failed", Self.failureFields(for: error).merging(["voice": voiceId]) { $1 })
            throw VoiceCatalogCoordinatorError.install(error)
        } catch {
            log.record("install.failed", ["voice": voiceId, "kind": "other"])
            throw error
        }
        let bytesOnDisk = Self.byteCount(of: folder)
        log.record("install.finished", ["voice": voiceId, "version": row.entry.version, "bytesOnDisk": String(bytesOnDisk)])
        recordInLedger(voiceId: voiceId, folder: folder)
        return folder
    }

    /// Deletes this voice's files and its Storage row. Other voices, and bundled ones, are untouched.
    public func remove(voiceId: String) async throws {
        let bytesFreed = installer.installedVersions(voiceId: voiceId)
            .compactMap { installer.installedFolder(voiceId: voiceId, version: $0) }
            .reduce(Int64(0)) { $0 + Self.byteCount(of: $1) }
        do {
            try await installer.remove(voiceId: voiceId)
        } catch let error as VoiceModelInstallError {
            log.record("remove.failed", Self.failureFields(for: error).merging(["voice": voiceId]) { $1 })
            throw VoiceCatalogCoordinatorError.install(error)
        }
        log.record("remove.done", ["voice": voiceId, "bytesFreed": String(bytesFreed)])
        try? repository?.deleteOwnedOfflineAsset(id: Self.ledgerAssetId(voiceId: voiceId))
    }

    public static func ledgerAssetId(voiceId: String) -> String { ledgerAssetPrefix + voiceId }

    /// The installer names a version's folder with letters, digits, dot, dash and underscore only, and a
    /// catalog version can hold more (Supertonic's is `3cadd1e+int8-2026-05-11`). Anything else becomes `_`.
    public static func folderName(forVersion version: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var name = String(version.prefix(64).map { allowed.contains($0) ? $0 : "_" })
        if name.isEmpty || name.hasPrefix(".") { name = "v" + name.prefix(63) }
        return name
    }

    /// The ledger row for an installed voice: one row for the voice's folder (reconciliation leaves a row
    /// that names a folder alone), not reproducible, so Storage never clears it on its own.
    public static func ledgerAsset(voiceId: String, byteCount: Int64, at moment: Date) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: ledgerAssetId(voiceId: voiceId),
            category: ledgerCategory,
            relativePath: "\(voicesFolderName)/\(voiceId)",
            byteCount: byteCount,
            isReproducible: false,
            lastAccessedAt: moment,
            createdAt: moment
        )
    }

    private func recordInLedger(voiceId: String, folder: URL) {
        try? repository?.saveOwnedOfflineAsset(Self.ledgerAsset(voiceId: voiceId, byteCount: Self.byteCount(of: folder), at: now()))
    }

    // MARK: Words

    /// The installer's errors as log fields: a kind, and the numbers or names that explain it.
    static func failureFields(for error: VoiceModelInstallError) -> [String: String] {
        switch error {
        case .invalidRequest(let reason): ["kind": "invalid request", "reason": reason]
        case .insufficientSpace(let needed, let available):
            ["kind": "not enough space", "neededBytes": String(needed), "availableBytes": String(available)]
        case .downloadFailed(let path, let problem): ["kind": "download failed", "file": path, "reason": problem]
        case .checksumMismatch(let path): ["kind": "checksum mismatch", "file": path]
        case .busy: ["kind": "already running"]
        case .storageFailed(let reason): ["kind": "storage failed", "reason": reason]
        case .preparationFailed(let reason): ["kind": "preparation failed", "reason": reason]
        }
    }

    /// The installer's errors in the words the Voices screen shows.
    public static func plainWords(for error: VoiceModelInstallError) -> String {
        switch error {
        case .insufficientSpace(let needed, _):
            "Not enough space: needs \(megabytes(needed)) MB."
        case .downloadFailed(_, let problem):
            "The download stopped: \(problem). Try again to continue where it left off."
        case .checksumMismatch:
            "A file arrived damaged and was thrown away. Try again."
        case .busy:
            "This voice is already downloading."
        case .preparationFailed:
            "The voice downloaded but couldn't be prepared. Try again; it won't download again."
        case .invalidRequest, .storageFailed:
            error.errorDescription ?? "The voice couldn't be saved."
        }
    }

    /// Decimal megabytes, rounded up.
    public static func megabytes(_ bytes: Int64) -> Int64 { (max(bytes, 0) + 999_999) / 1_000_000 }

    static func byteCount(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
