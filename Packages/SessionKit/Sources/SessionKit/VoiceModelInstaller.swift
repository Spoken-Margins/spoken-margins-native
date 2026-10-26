#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Installs a downloadable voice (#1817, slice of #1392): checks there's room, downloads each file
// into a staging folder (resuming a partial file, trying the next source when one fails), checks every
// SHA-256, and only then moves the whole folder into `<root>/<voice id>/<version>/` in one rename.
// A failed install or upgrade never touches an installed version. Nothing in the app calls this yet;
// background URLSession wiring and the storage ledger belong to the Settings issue.
//
// A file the publisher ships only inside an archive (#2086) is taken out of it: the archive downloads
// once into the staging folder like any file, is checked, is streamed through the decompressor to write
// each named member to its own path (each member checked too), and is deleted before the folder moves.
// Peak disk use is the archive plus the members taken out of it, on top of the other files.

public struct VoiceModelInstallFile: Equatable, Sendable {
    /// Where the file lands inside the voice's folder, e.g. `onnx/tts.json`.
    public var path: String
    public var byteCount: Int
    /// Lowercase hex.
    public var sha256: String
    /// HTTPS URLs in order of preference. Empty for an archive member or carried content.
    public var sources: [String]
    /// The member of one of the install's archives that holds these bytes.
    public var archiveMember: VoiceModelArchiveMember?
    /// The bytes themselves, when the signed catalog carries them.
    public var content: Data?

    public init(path: String, byteCount: Int, sha256: String, sources: [String]) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sources = sources
    }

    public init(path: String, byteCount: Int, sha256: String, archiveMember: VoiceModelArchiveMember) {
        self.init(path: path, byteCount: byteCount, sha256: sha256, sources: [])
        self.archiveMember = archiveMember
    }

    public init(path: String, byteCount: Int, sha256: String, content: Data) {
        self.init(path: path, byteCount: byteCount, sha256: sha256, sources: [])
        self.content = content
    }

    var isDownloaded: Bool { archiveMember == nil && content == nil }
}

/// An archive some of an install's files are taken from. Downloaded and checked like a file, then deleted.
public struct VoiceModelInstallArchive: Equatable, Sendable {
    public var id: String
    public var format: String
    public var byteCount: Int
    public var sha256: String
    public var sources: [String]

    public init(id: String, format: String, byteCount: Int, sha256: String, sources: [String]) {
        self.id = id
        self.format = format
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sources = sources
    }

    /// Where it sits in the staging folder while it is needed. Hidden, so it is never installed.
    var stagingPath: String { "\(VoiceModelInstaller.archiveFolder)/\(id).\(format)" }
}

extension VoiceModelEntry {
    /// The installer's view of this voice: every file, and every archive a file is taken from.
    public var installFiles: [VoiceModelInstallFile] {
        files.map { file in
            if let member = file.archiveMember {
                return VoiceModelInstallFile(path: file.path, byteCount: file.byteCount, sha256: file.sha256, archiveMember: member)
            }
            if let content = file.content {
                return VoiceModelInstallFile(path: file.path, byteCount: file.byteCount, sha256: file.sha256, content: Data(content.utf8))
            }
            return VoiceModelInstallFile(path: file.path, byteCount: file.byteCount, sha256: file.sha256, sources: file.sources)
        }
    }

    public var installArchives: [VoiceModelInstallArchive] {
        let used = Set(files.compactMap(\.archiveMember?.archive))
        return archives.filter { used.contains($0.id) }.map {
            VoiceModelInstallArchive(id: $0.id, format: $0.format, byteCount: $0.byteCount, sha256: $0.sha256, sources: $0.sources)
        }
    }
}

public struct VoiceModelInstallProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case downloading
        /// Every file is in and checked; the runtime's one-time preparation is running (#2700).
        case preparing
    }

    /// Bytes of the voice in place so far, counting what an earlier attempt already downloaded.
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var phase: Phase = .downloading
}

public enum VoiceModelInstallError: Error, Equatable, LocalizedError {
    /// The voice id, version or file list is not one the installer will touch.
    case invalidRequest(String)
    /// Raised before any byte is downloaded. `neededBytes` includes the safety margin.
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)
    /// Every source for the file was tried. `problem` is the last one's plain-words reason.
    case downloadFailed(path: String, problem: String)
    /// A source sent the whole file and its SHA-256 was wrong. The staged download is deleted.
    case checksumMismatch(path: String)
    /// This voice is already being installed or removed.
    case busy(voiceId: String)
    case storageFailed(String)
    /// Every file arrived and checked, but the runtime's preparation failed. The files stay staged.
    case preparationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): "This voice can't be installed: \(reason)."
        case .insufficientSpace(let needed, let available):
            "This voice needs \(Self.megabytes(needed)) MB, \(Self.megabytes(available)) MB free."
        case .downloadFailed(let path, let problem): "Couldn't download \(path): \(problem)."
        case .checksumMismatch(let path): "\(path) downloaded but didn't match what was expected, so it was thrown away."
        case .busy: "This voice is already being installed or removed."
        case .storageFailed(let reason): "Couldn't save the voice: \(reason)."
        case .preparationFailed(let reason): "The voice downloaded but couldn't be prepared: \(reason)."
        }
    }

    /// Decimal megabytes, rounded up, so the message never promises room that isn't there.
    private static func megabytes(_ bytes: Int64) -> Int64 { (max(bytes, 0) + 999_999) / 1_000_000 }
}

public actor VoiceModelInstaller {
    public struct Configuration: Sendable {
        /// Kept free on top of the download, so a full install doesn't leave the phone with nothing.
        public var marginBytes: Int64
        /// Tries on one source for a dropped connection or a server error, before the next source.
        public var attemptsPerSource: Int
        public var retryDelay: Duration
        /// Free bytes on the volume holding the given folder, or nil when unknown (then nothing is refused).
        public var availableCapacity: @Sendable (URL) -> Int64?
        /// Opens the archives some voices' files are taken from.
        public var decompressor: any VoiceModelArchiveDecompressor
        /// Where each file's start, retries and finish are recorded for Diagnostics (#2224). Nil: not recorded.
        public var log: VoiceDownloadLog?

        public init(
            marginBytes: Int64 = 50_000_000,
            attemptsPerSource: Int = 3,
            retryDelay: Duration = .seconds(1),
            availableCapacity: @escaping @Sendable (URL) -> Int64? = VoiceModelInstaller.volumeAvailableBytes,
            decompressor: any VoiceModelArchiveDecompressor = BZip2ArchiveDecompressor(),
            log: VoiceDownloadLog? = nil
        ) {
            self.marginBytes = marginBytes
            self.attemptsPerSource = attemptsPerSource
            self.retryDelay = retryDelay
            self.availableCapacity = availableCapacity
            self.decompressor = decompressor
            self.log = log
        }
    }

    private static let stagingFolder = ".staging"
    static let archiveFolder = ".archives"
    private static let partialSuffix = ".partial"

    private let root: URL
    private let transport: VoiceModelTransport
    private let configuration: Configuration
    private var busyVoices: Set<String> = []

    /// `root` is the folder voices live in, normally inside Application Support.
    public init(root: URL, transport: VoiceModelTransport = URLSessionVoiceModelTransport(), configuration: Configuration = Configuration()) {
        self.root = root
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: Reading what's installed

    /// The folder of an installed voice version, or nil when that version isn't installed.
    public nonisolated func installedFolder(voiceId: String, version: String) -> URL? {
        guard Self.isSafeName(voiceId), Self.isSafeName(version) else { return nil }
        let folder = root.appendingPathComponent(voiceId, isDirectory: true).appendingPathComponent(version, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : nil
    }

    /// Versions of a voice that are fully installed. An install in progress is never listed.
    public nonisolated func installedVersions(voiceId: String) -> [String] {
        guard Self.isSafeName(voiceId) else { return [] }
        let folder = root.appendingPathComponent(voiceId, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Install and remove

    /// Installs `version` of the voice and returns its folder. Once it is in place, other versions of the
    /// same voice are deleted. Throws `CancellationError` when the task is cancelled; a partial download
    /// stays staged so a later call resumes it. Progress counts downloaded bytes: each downloaded file and
    /// each archive, which is what `VoiceModelEntry.downloadByteCount` shows the listener.
    ///
    /// `prepare`, when given, runs once every file is checked, on the staged folder, before it moves into
    /// place (#2700); progress reports `.preparing` while it runs. A preparation error leaves the voice
    /// uninstalled with its files still staged, so the next call prepares again without downloading.
    @discardableResult
    public func install(
        voiceId: String,
        version: String,
        files: [VoiceModelInstallFile],
        archives: [VoiceModelInstallArchive] = [],
        progress: (@Sendable (VoiceModelInstallProgress) -> Void)? = nil,
        prepare: (@Sendable (URL) async throws -> Void)? = nil,
        preparationBytes: Int64 = 0
    ) async throws -> URL {
        try Self.validate(voiceId: voiceId, version: version, files: files, archives: archives, formats: configuration.decompressor.formats)
        guard busyVoices.insert(voiceId).inserted else { throw VoiceModelInstallError.busy(voiceId: voiceId) }
        defer { busyVoices.remove(voiceId) }

        let staging = stagingURL(voiceId: voiceId, version: version)
        let total = files.filter(\.isDownloaded).reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            + archives.reduce(Int64(0)) { $0 + Int64($1.byteCount) }

        try refuseIfNoRoom(files: files, archives: archives, staging: staging, preparationBytes: prepare == nil ? 0 : preparationBytes)

        try createFolder(root)
        try createFolder(root.appendingPathComponent(Self.stagingFolder, isDirectory: true))
        try createFolder(staging)
        recoverReplaced(voiceId: voiceId)
        try pruneStaging(staging, keeping: files, archives: archives)

        let tracker = ProgressTracker(total: total, report: progress)
        for file in files where file.isDownloaded {
            try await stage(file, in: staging, tracker: tracker)
        }
        for file in files {
            if let content = file.content { try place(content, as: file, in: staging) }
        }
        for archive in archives {
            try await unpack(archive, members: files.filter { $0.archiveMember?.archive == archive.id }, in: staging, tracker: tracker)
        }
        try removeIfPresent(staging.appendingPathComponent(Self.archiveFolder, isDirectory: true))

        if let prepare {
            try Task.checkCancellation()
            progress?(VoiceModelInstallProgress(bytesDownloaded: total, totalBytes: total, phase: .preparing))
            configuration.log?.record("prepare.started", ["voice": voiceId, "version": version])
            do {
                try await prepare(staging)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Whatever the preparation half wrote (a compiled folder, say) goes now, folders included, so the
                // retry starts from the checked downloads alone and a preparer's move into place can't hit
                // "file exists" (#2735 review).
                try? pruneStaging(staging, keeping: files, archives: archives)
                configuration.log?.record("prepare.failed", ["voice": voiceId, "reason": String(describing: error)])
                throw VoiceModelInstallError.preparationFailed(String(describing: error))
            }
            configuration.log?.record("prepare.finished", ["voice": voiceId, "version": version])
        }

        return try finalize(staging: staging, voiceId: voiceId, version: version)
    }

    /// Deletes one voice: every installed version and anything staged for it. Other voices are untouched.
    public func remove(voiceId: String) throws {
        try Self.validateName(voiceId, what: "voice id")
        guard busyVoices.insert(voiceId).inserted else { throw VoiceModelInstallError.busy(voiceId: voiceId) }
        defer { busyVoices.remove(voiceId) }

        let fileManager = FileManager.default
        let staged = (try? fileManager.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        for name in staged where name.hasPrefix(voiceId + "@") {
            try removeIfPresent(stagingRoot.appendingPathComponent(name, isDirectory: true))
        }
        try removeIfPresent(root.appendingPathComponent(voiceId, isDirectory: true))
    }

    // MARK: Space

    public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
        // The folder may not exist yet; measure the nearest one that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        #if canImport(Darwin)
        if let bytes = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            return bytes
        }
        #endif
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: probe.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Counts what is still to be written: the rest of each download, each archive member and carried file
    /// not yet in place, and the rest of each archive whose members aren't all out of it yet. An archive is
    /// on disk at the same time as its members, so both count.
    /// `preparationBytes` is what the runtime's preparation writes beside the files (a compiled Core ML copy).
    private func refuseIfNoRoom(
        files: [VoiceModelInstallFile],
        archives: [VoiceModelInstallArchive],
        staging: URL,
        preparationBytes: Int64
    ) throws {
        func stillToWrite(_ path: String, _ byteCount: Int) -> Int64 {
            let have = Self.sizeOfFile(at: staging.appendingPathComponent(path))
                ?? Self.sizeOfFile(at: staging.appendingPathComponent(path + Self.partialSuffix))
                ?? 0
            return max(0, Int64(byteCount) - min(have, Int64(byteCount)))
        }
        var stillToDownload: Int64 = 0
        for file in files {
            stillToDownload += stillToWrite(file.path, file.byteCount)
        }
        for archive in archives {
            let members = files.filter { $0.archiveMember?.archive == archive.id }
            let done = members.allSatisfy { Self.sizeOfFile(at: staging.appendingPathComponent($0.path)) == Int64($0.byteCount) }
            if !done { stillToDownload += stillToWrite(archive.stagingPath, archive.byteCount) }
        }
        let needed = stillToDownload + max(0, preparationBytes) + configuration.marginBytes
        if let available = configuration.availableCapacity(root), available < needed {
            throw VoiceModelInstallError.insufficientSpace(neededBytes: needed, availableBytes: available)
        }
    }

    // MARK: One file

    private enum SourceProblem: Error {
        /// Worth another try on the same source: a dropped connection, a timeout, a server error.
        case transient(String)
        /// This source can't give the file: not found, refused, bad address, TLS failure, wrong size.
        case unusable(String)
        case wrongChecksum
    }

    private func stage(_ file: VoiceModelInstallFile, in staging: URL, tracker: ProgressTracker) async throws {
        let finalURL = staging.appendingPathComponent(file.path)
        let partialURL = staging.appendingPathComponent(file.path + Self.partialSuffix)

        // Finished in an earlier attempt: trust it only if it still hashes right.
        if Self.sizeOfFile(at: finalURL) == Int64(file.byteCount) {
            if try Self.sha256(of: finalURL) == file.sha256 {
                tracker.complete(Int64(file.byteCount))
                configuration.log?.record("file.in_place", ["file": file.path, "bytes": String(file.byteCount)])
                return
            }
        }
        try removeIfPresent(finalURL)
        try createFolder(finalURL.deletingLastPathComponent())

        var lastProblem = "no source could be reached"
        var sawWrongChecksum = false
        // A wrong hash on a download that continued an older partial may only mean the old bytes were
        // stale, so that gets one clean start before the source is blamed.
        var cleanStartSpent = false
        for source in file.sources {
            guard let url = Self.usableURL(source) else {
                lastProblem = "\(source) is not a usable address"
                configuration.log?.record("file.source_failed", ["file": file.path, "host": VoiceDownloadLog.host(of: source), "reason": "not a usable address"])
                continue
            }
            var attempt = 0
            sourceLoop: while attempt < max(1, configuration.attemptsPerSource) {
                attempt += 1
                try Task.checkCancellation()
                let continuedPartial = (Self.sizeOfFile(at: partialURL) ?? 0) > 0
                do {
                    try await download(file, from: url, into: partialURL, tracker: tracker)
                    guard try Self.sha256(of: partialURL) == file.sha256 else { throw SourceProblem.wrongChecksum }
                    try removeIfPresent(finalURL)
                    try FileManager.default.moveItem(at: partialURL, to: finalURL)
                    tracker.complete(Int64(file.byteCount))
                    configuration.log?.record("file.done", ["file": file.path, "bytes": String(file.byteCount), "host": VoiceDownloadLog.host(of: source), "attempt": String(attempt)])
                    return
                } catch SourceProblem.transient(let reason) {
                    lastProblem = reason
                    let willRetry = configuration.attemptsPerSource > attempt
                    configuration.log?.record("file.attempt_failed", [
                        "file": file.path, "host": VoiceDownloadLog.host(of: source), "attempt": String(attempt),
                        "reason": reason, "willRetry": willRetry ? "yes" : "no, next source"
                    ])
                    if willRetry, configuration.retryDelay > .zero {
                        try await Task.sleep(for: configuration.retryDelay)
                    }
                } catch SourceProblem.unusable(let reason) {
                    lastProblem = reason
                    configuration.log?.record("file.source_failed", ["file": file.path, "host": VoiceDownloadLog.host(of: source), "reason": reason])
                    break sourceLoop
                } catch SourceProblem.wrongChecksum {
                    try removeIfPresent(partialURL)
                    tracker.set(0)
                    configuration.log?.record("file.checksum_mismatch", [
                        "file": file.path, "host": VoiceDownloadLog.host(of: source),
                        "continuedPartial": continuedPartial ? "yes" : "no"
                    ])
                    if continuedPartial, !cleanStartSpent {
                        cleanStartSpent = true
                        attempt -= 1
                        continue sourceLoop
                    }
                    sawWrongChecksum = true
                    lastProblem = "the file didn't match its checksum"
                    break sourceLoop
                }
            }
            // The next source continues any partial file; the checksum decides whether the bytes line up.
        }

        if sawWrongChecksum {
            // Definitive: throw the whole staged download away so a retry starts clean.
            try? removeIfPresent(staging)
            throw VoiceModelInstallError.checksumMismatch(path: file.path)
        }
        throw VoiceModelInstallError.downloadFailed(path: file.path, problem: lastProblem)
    }

    /// Fetches `file` from one URL into `partialURL`, continuing whatever is already there, until it holds
    /// exactly `byteCount` bytes. Throws a `SourceProblem` otherwise.
    private func download(_ file: VoiceModelInstallFile, from url: URL, into partialURL: URL, tracker: ProgressTracker) async throws {
        let byteCount = Int64(file.byteCount)
        var offset = Self.sizeOfFile(at: partialURL) ?? 0
        if offset > byteCount {
            try removeIfPresent(partialURL)
            offset = 0
        }
        if offset == byteCount {
            if !FileManager.default.fileExists(atPath: partialURL.path) { _ = FileManager.default.createFile(atPath: partialURL.path, contents: nil) }
            return
        }

        let sink: FileSink
        do {
            sink = try FileSink(url: partialURL, startingAt: offset, limit: byteCount)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
        defer { sink.close() }
        tracker.set(offset)
        let log = configuration.log
        let hadPartial = offset > 0
        log?.record("file.download", [
            "file": file.path, "host": VoiceDownloadLog.host(of: url.absoluteString), "bytes": String(byteCount),
            "resumedFromBytes": String(offset)
        ])

        do {
            try await transport.fetch(
                url,
                from: Int(offset),
                onHead: { head in
                    switch head.statusCode {
                    case 206:
                        // The server must continue exactly where the partial file ends.
                        guard head.contentRangeStart == Int(sink.startOffset) else { throw SourceProblem.unusable("the server resumed at the wrong byte") }
                        return true
                    case 200:
                        // The server ignored the range and is sending the whole file.
                        if hadPartial { log?.record("file.restarted", ["file": file.path, "reason": "the server ignored the resume point"]) }
                        try sink.restartFromZero()
                        tracker.set(0)
                        return true
                    case 408, 429, 500...599:
                        throw SourceProblem.transient("the server answered HTTP \(head.statusCode)")
                    case 416:
                        log?.record("file.restarted", ["file": file.path, "reason": "the server rejected the resume point"])
                        try sink.restartFromZero()
                        tracker.set(0)
                        throw SourceProblem.transient("the server rejected the resume point")
                    default:
                        throw SourceProblem.unusable("the server answered HTTP \(head.statusCode)")
                    }
                },
                onChunk: { data in
                    tracker.set(try sink.append(data))
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let problem as SourceProblem {
            throw problem
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw Self.isTransportFatal(error) ? SourceProblem.unusable(Self.describe(error)) : SourceProblem.transient(Self.describe(error))
        } catch is FileSink.TooLong {
            try removeIfPresent(partialURL)
            tracker.set(0)
            throw SourceProblem.unusable("the server sent more bytes than expected")
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }

        sink.close()
        if sink.written < byteCount {
            // Cut short without an error. Keep what arrived: the next try resumes from here.
            throw SourceProblem.transient("the connection ended after \(sink.written) of \(byteCount) bytes")
        }
    }

    private static func isTransportFatal(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection:
            true
        default:
            false
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "the connection timed out"
        case .notConnectedToInternet: "there is no internet connection"
        case .networkConnectionLost: "the connection was lost"
        default:
            isTransportFatal(error) ? "the secure connection failed" : "a network error (\(error.code.rawValue))"
        }
    }

    // MARK: Archives and carried files

    /// Writes bytes the catalog carries, after checking them.
    private func place(_ content: Data, as file: VoiceModelInstallFile, in staging: URL) throws {
        let finalURL = staging.appendingPathComponent(file.path)
        guard content.count == file.byteCount, Self.hex(SHA256.hash(data: content)) == file.sha256 else {
            throw VoiceModelInstallError.checksumMismatch(path: file.path)
        }
        try createFolder(finalURL.deletingLastPathComponent())
        do {
            try content.write(to: finalURL, options: .atomic)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
    }

    /// Takes `members` out of `archive`. Members already in place with the right bytes are kept, so an
    /// install that stopped after unpacking doesn't download the archive again. Otherwise the archive is
    /// downloaded (or resumed) and checked like any file, each member is written to its own path while it
    /// is hashed, and the archive is deleted once every member is out.
    private func unpack(_ archive: VoiceModelInstallArchive, members: [VoiceModelInstallFile], in staging: URL, tracker: ProgressTracker) async throws {
        var missing: [String: VoiceModelInstallFile] = [:]
        for file in members {
            let url = staging.appendingPathComponent(file.path)
            if Self.sizeOfFile(at: url) == Int64(file.byteCount), try Self.sha256(of: url) == file.sha256 { continue }
            try removeIfPresent(url)
            if let member = file.archiveMember?.member { missing[member] = file }
        }
        let archiveURL = staging.appendingPathComponent(archive.stagingPath)
        guard !missing.isEmpty else {
            tracker.complete(Int64(archive.byteCount))
            try removeIfPresent(archiveURL)
            return
        }
        let asFile = VoiceModelInstallFile(path: archive.stagingPath, byteCount: archive.byteCount, sha256: archive.sha256, sources: archive.sources)
        try await stage(asFile, in: staging, tracker: tracker)

        let extraction = MemberExtraction(staging: staging, wanted: missing)
        let reader = TarStreamReader(
            onMember: { try extraction.begin($0) },
            onData: { try extraction.write($0) },
            onMemberEnd: { try extraction.end($0) }
        )
        do {
            try configuration.decompressor.tarBytes(of: archiveURL, format: archive.format) { chunk in
                if Task.isCancelled { throw CancellationError() }
                try reader.feed(chunk)
            }
            try reader.finish()
        } catch is CancellationError {
            extraction.abandon()
            throw CancellationError()
        } catch let error as VoiceModelInstallError {
            extraction.abandon()
            if case .checksumMismatch = error {
                // The archive matched its hash, so a member that doesn't is the catalog's mistake; start clean.
                try? removeIfPresent(staging)
            }
            throw error
        } catch {
            extraction.abandon()
            // The archive matched its hash, so bytes that won't unpack can't be fixed by downloading again.
            try? removeIfPresent(archiveURL)
            throw VoiceModelInstallError.downloadFailed(path: archive.stagingPath, problem: "the archive couldn't be unpacked (\(error))")
        }
        if let left = extraction.remaining.first {
            extraction.abandon()
            throw VoiceModelInstallError.downloadFailed(path: left.path, problem: "the archive has no member \(left.archiveMember?.member ?? "")")
        }
        try removeIfPresent(archiveURL)
    }

    // MARK: Finishing

    private func finalize(staging: URL, voiceId: String, version: String) throws -> URL {
        let fileManager = FileManager.default
        let voiceFolder = root.appendingPathComponent(voiceId, isDirectory: true)
        let destination = voiceFolder.appendingPathComponent(version, isDirectory: true)
        try createFolder(voiceFolder)

        do {
            // The staged folder is the only one with this version's files, so one rename puts them all in place.
            var displaced: URL?
            if fileManager.fileExists(atPath: destination.path) {
                let aside = stagingRoot.appendingPathComponent("\(voiceId)@\(version).replaced-\(UUID().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: destination, to: aside)
                displaced = aside
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                if let displaced { try? fileManager.moveItem(at: displaced, to: destination) }
                throw error
            }
            if let displaced { try? removeIfPresent(displaced) }
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }

        // The new version is in place, so older ones only take space. Best effort: a leftover is harmless.
        for name in (try? fileManager.contentsOfDirectory(atPath: voiceFolder.path)) ?? [] where name != version {
            try? removeIfPresent(voiceFolder.appendingPathComponent(name, isDirectory: true))
        }
        return destination
    }

    /// A reinstall of the same version sets the installed copy aside for a moment. If the app was killed in
    /// that moment, put the copy back; if the version is in place, the leftover is just garbage.
    private func recoverReplaced(voiceId: String) {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: stagingRoot.path)) ?? [] where name.hasPrefix(voiceId + "@") {
            guard let marker = name.range(of: ".replaced-") else { continue }
            let version = String(name[name.index(name.startIndex, offsetBy: voiceId.count + 1)..<marker.lowerBound])
            let aside = stagingRoot.appendingPathComponent(name, isDirectory: true)
            let destination = root.appendingPathComponent(voiceId, isDirectory: true).appendingPathComponent(version, isDirectory: true)
            if Self.isSafeName(version), !fileManager.fileExists(atPath: destination.path),
               (try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
               (try? fileManager.moveItem(at: aside, to: destination)) != nil {
                continue
            }
            try? removeIfPresent(aside)
        }
    }

    // MARK: Folders

    private var stagingRoot: URL { root.appendingPathComponent(Self.stagingFolder, isDirectory: true) }

    private func stagingURL(voiceId: String, version: String) -> URL {
        stagingRoot.appendingPathComponent("\(voiceId)@\(version)", isDirectory: true)
    }

    /// Creates a folder and keeps it out of iCloud and device backups: the files can be downloaded again.
    private func createFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = url
        try? folder.setResourceValues(values)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
    }

    /// Deletes anything staged that the file list doesn't name, so the folder that gets installed holds
    /// exactly the listed files. An archive still to be unpacked is kept. Folders that hold no listed file go
    /// too, so a half-written preparation output (`compiled/x.mlmodelc/`) can't survive as empty folders that
    /// make the next preparation's move fail (#2735 review). A link is removed as a link, never followed.
    private func pruneStaging(_ staging: URL, keeping files: [VoiceModelInstallFile], archives: [VoiceModelInstallArchive]) throws {
        let wanted = Set(files.map(\.path).flatMap { [$0, $0 + Self.partialSuffix] }
            + archives.map(\.stagingPath).flatMap { [$0, $0 + Self.partialSuffix] })
        var wantedFolders: Set<String> = []
        for path in wanted {
            var components = Array(path.split(separator: "/").dropLast())
            while !components.isEmpty {
                wantedFolders.insert(components.joined(separator: "/"))
                components.removeLast()
            }
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: keys) else { return }
        let base = staging.standardizedFileURL.path + "/"
        var unwanted: [URL] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if isFolder {
                if wantedFolders.contains(relative) { continue }
                enumerator.skipDescendants()
                unwanted.append(url)
            } else if !wanted.contains(relative) {
                unwanted.append(url)
            }
        }
        for url in unwanted { try removeIfPresent(url) }
    }

    // MARK: Checks

    private static func validate(
        voiceId: String,
        version: String,
        files: [VoiceModelInstallFile],
        archives: [VoiceModelInstallArchive],
        formats: Set<String>
    ) throws {
        try validateName(voiceId, what: "voice id")
        try validateName(version, what: "version")
        guard !files.isEmpty else { throw VoiceModelInstallError.invalidRequest("the file list is empty") }
        var archiveIDs: Set<String> = []
        for archive in archives {
            guard isSafeName(archive.id), isSafeName(archive.format), archiveIDs.insert(archive.id).inserted else {
                throw VoiceModelInstallError.invalidRequest("\"\(archive.id)\" is not a usable archive id")
            }
            guard formats.contains(archive.format) else {
                throw VoiceModelInstallError.invalidRequest("this build can't open \(archive.format) archives")
            }
            guard archive.byteCount >= 1, archive.sha256.count == 64, archive.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw VoiceModelInstallError.invalidRequest("archive \(archive.id) has a malformed size or checksum")
            }
            guard !archive.sources.isEmpty else { throw VoiceModelInstallError.invalidRequest("archive \(archive.id) has no sources") }
        }
        var members: Set<String> = []
        var paths: Set<String> = []
        for file in files {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let clean = !components.isEmpty && components.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
            }
            guard clean, !file.path.hasSuffix(partialSuffix) else {
                throw VoiceModelInstallError.invalidRequest("\(file.path) is not a safe file path")
            }
            guard paths.insert(file.path).inserted else { throw VoiceModelInstallError.invalidRequest("\(file.path) is listed twice") }
            guard file.byteCount >= 0 else { throw VoiceModelInstallError.invalidRequest("\(file.path) has a negative size") }
            guard file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw VoiceModelInstallError.invalidRequest("\(file.path) has a malformed checksum")
            }
            let places = (file.sources.isEmpty ? 0 : 1) + (file.archiveMember == nil ? 0 : 1) + (file.content == nil ? 0 : 1)
            guard places == 1 else {
                throw VoiceModelInstallError.invalidRequest(places == 0 ? "\(file.path) has no sources" : "\(file.path) names more than one source of bytes")
            }
            if let member = file.archiveMember {
                guard archiveIDs.contains(member.archive) else {
                    throw VoiceModelInstallError.invalidRequest("\(file.path) names archive \(member.archive), which isn't listed")
                }
                guard members.insert(member.archive + "\u{0}" + member.member).inserted else {
                    throw VoiceModelInstallError.invalidRequest("\(member.member) is taken out twice")
                }
            }
        }
        // An archive no file is taken from would be downloaded for nothing.
        for id in archiveIDs where !files.contains(where: { $0.archiveMember?.archive == id }) {
            throw VoiceModelInstallError.invalidRequest("archive \(id) gives no file")
        }
        // A file and a folder can't share a path.
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            for length in 1..<max(parts.count, 1) where paths.contains(parts.prefix(length).joined(separator: "/")) {
                throw VoiceModelInstallError.invalidRequest("\(path) sits inside another listed file")
            }
        }
    }

    private static func validateName(_ name: String, what: String) throws {
        guard isSafeName(name) else { throw VoiceModelInstallError.invalidRequest("\"\(name)\" is not a usable \(what)") }
    }

    /// Letters, digits, dot, dash and underscore; no leading dot, so it can't escape the root or hide.
    static func isSafeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars)
        return first != "." && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Plain HTTPS, or HTTP to this machine for tests. Credentials in the address are never sent.
    private static func usableURL(_ source: String) -> URL? {
        guard let components = URLComponents(string: source), let url = components.url,
              components.user == nil, components.password == nil, components.host?.isEmpty == false else { return nil }
        let scheme = components.scheme?.lowercased()
        if scheme == "https" { return url }
        return scheme == "http" && URLSessionVoiceModelTransport.isLoopback(url) ? url : nil
    }

    private static func sizeOfFile(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw VoiceModelInstallError.storageFailed(error.localizedDescription) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Writes the wanted members of one tar stream to their own paths in the staging folder, each to a
/// `.partial` file while it is hashed, moved into place only when its size and SHA-256 match.
private final class MemberExtraction {
    private let staging: URL
    private var wanted: [String: VoiceModelInstallFile]
    private var current: (file: VoiceModelInstallFile, handle: FileHandle, hasher: SHA256, written: Int64, partial: URL)?

    init(staging: URL, wanted: [String: VoiceModelInstallFile]) {
        self.staging = staging
        self.wanted = wanted
    }

    var remaining: [VoiceModelInstallFile] { wanted.values.sorted { $0.path < $1.path } }

    func begin(_ member: TarStreamReader.Member) throws -> Bool {
        guard let file = wanted[member.path] else { return false }
        guard member.size == Int64(file.byteCount) else { throw VoiceModelInstallError.checksumMismatch(path: file.path) }
        let target = staging.appendingPathComponent(file.path)
        let partial = staging.appendingPathComponent(file.path + ".partial")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            current = (file, try FileHandle(forWritingTo: partial), SHA256(), 0, partial)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
        return true
    }

    func write(_ data: Data) throws {
        guard var entry = current else { return }
        do {
            try entry.handle.write(contentsOf: data)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
        entry.hasher.update(data: data)
        entry.written += Int64(data.count)
        current = entry
    }

    func end(_ member: TarStreamReader.Member) throws {
        guard let entry = current, wanted[member.path] != nil else { return }
        current = nil
        try? entry.handle.close()
        let digest = entry.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard entry.written == Int64(entry.file.byteCount), digest == entry.file.sha256 else {
            try? FileManager.default.removeItem(at: entry.partial)
            throw VoiceModelInstallError.checksumMismatch(path: entry.file.path)
        }
        let target = staging.appendingPathComponent(entry.file.path)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: entry.partial, to: target)
        } catch {
            throw VoiceModelInstallError.storageFailed(error.localizedDescription)
        }
        wanted[member.path] = nil
    }

    /// Closes and deletes a member cut off part-way.
    func abandon() {
        guard let entry = current else { return }
        current = nil
        try? entry.handle.close()
        try? FileManager.default.removeItem(at: entry.partial)
    }
}

/// Reports bytes in place across files, safe to call from the transport's callbacks.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: (@Sendable (VoiceModelInstallProgress) -> Void)?
    private var finishedFiles: Int64 = 0
    private var currentFile: Int64 = 0

    init(total: Int64, report: (@Sendable (VoiceModelInstallProgress) -> Void)?) {
        self.total = total
        self.report = report
    }

    /// The file being downloaded now holds `bytes`.
    func set(_ bytes: Int64) {
        lock.lock()
        currentFile = bytes
        let snapshot = VoiceModelInstallProgress(bytesDownloaded: min(finishedFiles + currentFile, total), totalBytes: total)
        lock.unlock()
        report?(snapshot)
    }

    func complete(_ size: Int64) {
        lock.lock()
        finishedFiles += size
        currentFile = 0
        let snapshot = VoiceModelInstallProgress(bytesDownloaded: min(finishedFiles, total), totalBytes: total)
        lock.unlock()
        report?(snapshot)
    }
}

/// Appends a download to a partial file, refusing to grow past the expected size.
private final class FileSink: @unchecked Sendable {
    struct TooLong: Error {}

    private let lock = NSLock()
    private let handle: FileHandle
    private let limit: Int64
    private var count: Int64
    private var closed = false
    /// Where this request asked the server to start.
    let startOffset: Int64

    init(url: URL, startingAt offset: Int64, limit: Int64) throws {
        if offset == 0 {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.limit = limit
        self.count = offset
        self.startOffset = offset
    }

    var written: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Returns how many bytes the file holds now.
    func append(_ data: Data) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard count + Int64(data.count) <= limit else { throw TooLong() }
        try handle.write(contentsOf: data)
        count += Int64(data.count)
        return count
    }

    /// The server is sending the whole file, so what was kept no longer lines up.
    func restartFromZero() throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        count = 0
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
