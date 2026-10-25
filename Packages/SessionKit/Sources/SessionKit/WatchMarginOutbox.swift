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

/// Sent with a Watch Margin's audio file, Watch to phone (#788).
public struct WatchMarginTransferMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var captureId: String
    public var audioFileExtension: String
    public var byteCount: Int
    public var sha256: String
    public var durationMs: Int
    public var recordedAt: Date
    /// The phone's anchor, when its acknowledgement reached the Watch before the transfer.
    public var anchor: WatchCaptureAnchorOutcome?

    public init(
        schemaVersion: String = "watch-margin-transfer.v1",
        captureId: String,
        audioFileExtension: String,
        byteCount: Int,
        sha256: String,
        durationMs: Int,
        recordedAt: Date,
        anchor: WatchCaptureAnchorOutcome?
    ) {
        self.schemaVersion = schemaVersion
        self.captureId = captureId
        self.audioFileExtension = audioFileExtension
        self.byteCount = byteCount
        self.sha256 = sha256
        self.durationMs = durationMs
        self.recordedAt = recordedAt
        self.anchor = anchor
    }
}

// `WatchMarginReceipt` moved to WatchContract.swift (#2487 slice 1b), which the Watch app compiles too.

public enum WatchMarginStoreError: Error, Equatable {
    /// Capture ids name folders, so only letters, digits, `-` and `_` are allowed.
    case invalidCaptureId(String)
    case invalidFileExtension(String)
    case unknownCapture(String)
    /// The phone hasn't confirmed it holds this recording, so it can't be removed.
    case unsyncedAudio(String)
}

/// Folder-per-capture storage shared by the Watch outbox and the phone inbox.
///
/// A capture is staged in a hidden folder, flushed to storage and renamed into place in one step,
/// so after a crash or power loss a capture is either complete or absent. Staging folders left by
/// a crash are removed on open once they are older than `abandonedStagingAge`, so a second store
/// opened on the same folder can't remove a save still in progress. Open one store per folder.
struct WatchMarginFolderStore<Entry: Codable> {
    static var entryFileName: String { "entry.json" }
    static var abandonedStagingAge: TimeInterval { 60 }
    let directory: URL

    init(directory: URL, now: Date = Date()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix(".staging-") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let modified, now.timeIntervalSince(modified) < Self.abandonedStagingAge { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func validate(_ captureId: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !captureId.isEmpty, captureId.count <= 128,
              captureId.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw WatchMarginStoreError.invalidCaptureId(captureId)
        }
    }

    static func validate(fileExtension: String) throws {
        guard !fileExtension.isEmpty, fileExtension.count <= 8,
              fileExtension.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw WatchMarginStoreError.invalidFileExtension(fileExtension)
        }
    }

    func folder(_ captureId: String) -> URL {
        directory.appendingPathComponent(captureId, isDirectory: true)
    }

    func exists(_ captureId: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(captureId).appendingPathComponent(Self.entryFileName).path)
    }

    /// Copies `audio` and writes `entry` into a staging folder, then renames it into place.
    func commit(_ captureId: String, audio: URL, audioFileName: String, entry: Entry) throws {
        let staging = directory.appendingPathComponent(".staging-\(captureId)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let audioCopy = staging.appendingPathComponent(audioFileName)
            let entryFile = staging.appendingPathComponent(Self.entryFileName)
            try FileManager.default.copyItem(at: audio, to: audioCopy)
            try Self.encoder.encode(entry).write(to: entryFile, options: .atomic)
            try Self.flush(audioCopy)
            try Self.flush(entryFile)
            try Self.flush(staging)
            try FileManager.default.moveItem(at: staging, to: folder(captureId))
            try Self.flush(directory)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func write(_ captureId: String, entry: Entry) throws {
        let file = folder(captureId).appendingPathComponent(Self.entryFileName)
        try Self.encoder.encode(entry).write(to: file, options: .atomic)
        try Self.flush(file)
        try Self.flush(folder(captureId))
    }

    /// Forces a file's or folder's contents to storage, so "Saved" survives the Watch powering off.
    static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    func loadAll() throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !name.hasPrefix(".") {
            let file = folder(name).appendingPathComponent(Self.entryFileName)
            guard let data = try? Data(contentsOf: file) else { continue }
            entries[name] = try JSONDecoder().decode(Entry.self, from: data)
        }
        return entries
    }

    func remove(_ captureId: String) throws {
        try FileManager.default.removeItem(at: folder(captureId))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func digest(of file: URL) throws -> (byteCount: Int, sha256: String) {
        let data = try Data(contentsOf: file)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data.count, hex)
    }
}

/// The Watch's durable outbox of recorded Margins (#788).
///
/// `save` returns only once the recording and its metadata are on disk, so the Watch shows
/// "Saved" after it and never before. Entries stay until the phone's receipt confirms it holds the
/// same bytes; until then they survive restarts, an unreachable phone and failed transfers, and
/// can't be removed to make room.
public final class WatchMarginOutbox {
    public struct Entry: Codable, Equatable, Sendable {
        public enum State: String, Codable, Equatable, Sendable {
            /// On the Watch's disk, not yet sent (or the last send failed).
            case saved
            /// Handed to WatchConnectivity; it may still be queued.
            case transferring
            /// The phone's receipt confirmed it holds these bytes.
            case delivered
        }

        public var metadata: WatchMarginTransferMetadata
        public var state: State
        public var transferAttempts: Int
        public var lastError: String?

        public var captureId: String { metadata.captureId }
        var audioFileName: String { "audio.\(metadata.audioFileExtension)" }
    }

    private let store: WatchMarginFolderStore<Entry>
    private var entries: [String: Entry]

    public init(directory: URL) throws {
        store = try WatchMarginFolderStore(directory: directory)
        entries = try store.loadAll()
    }

    public func entry(_ captureId: String) -> Entry? {
        entries[captureId]
    }

    /// Recordings the phone hasn't confirmed, oldest first.
    public var undelivered: [Entry] {
        entries.values.filter { $0.state != .delivered }.sorted { ($0.metadata.recordedAt, $0.captureId) < ($1.metadata.recordedAt, $1.captureId) }
    }

    /// Copies the finished recording into the outbox. Saving the same capture again keeps the first.
    @discardableResult
    public func save(
        captureId: String,
        recording: URL,
        durationMs: Int,
        recordedAt: Date,
        anchor: WatchCaptureAnchorOutcome?
    ) throws -> Entry {
        try WatchMarginFolderStore<Entry>.validate(captureId)
        if let existing = entries[captureId] { return existing }
        let (byteCount, sha256) = try WatchMarginFolderStore<Entry>.digest(of: recording)
        let fileExtension = recording.pathExtension.isEmpty ? "m4a" : recording.pathExtension
        try WatchMarginFolderStore<Entry>.validate(fileExtension: fileExtension)
        let entry = Entry(
            metadata: WatchMarginTransferMetadata(
                captureId: captureId,
                audioFileExtension: fileExtension,
                byteCount: byteCount,
                sha256: sha256,
                durationMs: durationMs,
                recordedAt: recordedAt,
                anchor: anchor
            ),
            state: .saved,
            transferAttempts: 0,
            lastError: nil
        )
        try store.commit(captureId, audio: recording, audioFileName: entry.audioFileName, entry: entry)
        entries[captureId] = entry
        return entry
    }

    /// The phone's acknowledgement arrived after the recording was saved.
    public func setAnchor(_ anchor: WatchCaptureAnchorOutcome, for captureId: String) throws {
        try update(captureId) { $0.metadata.anchor = anchor }
    }

    /// The file and metadata to hand to WatchConnectivity. Counts an attempt.
    public func beginTransfer(_ captureId: String) throws -> (audio: URL, metadata: WatchMarginTransferMetadata) {
        let entry = try update(captureId) { entry in
            if entry.state != .delivered { entry.state = .transferring }
            entry.transferAttempts += 1
        }
        return (store.folder(captureId).appendingPathComponent(entry.audioFileName), entry.metadata)
    }

    /// The transfer failed or the phone was unreachable: keep it for the next try.
    public func transferFailed(_ captureId: String, error: String) throws {
        try update(captureId) { entry in
            guard entry.state != .delivered else { return }
            entry.state = .saved
            entry.lastError = error
        }
    }

    /// Applies the phone's receipt. Returns true when it confirmed delivery of these exact bytes.
    @discardableResult
    public func apply(_ receipt: WatchMarginReceipt) throws -> Bool {
        guard let entry = entries[receipt.captureId] else { return false }
        guard entry.state != .delivered else { return true }
        let confirmed = receipt.confirmsDelivery && receipt.sha256 == entry.metadata.sha256
        try update(receipt.captureId) { entry in
            if confirmed {
                entry.state = .delivered
                entry.lastError = nil
            } else {
                entry.state = .saved
                entry.lastError = "phone_\(receipt.status.rawValue)"
            }
        }
        return confirmed
    }

    /// Removes a delivered recording. Anything the phone hasn't confirmed is refused.
    public func evict(_ captureId: String) throws {
        guard let entry = entries[captureId] else { throw WatchMarginStoreError.unknownCapture(captureId) }
        guard entry.state == .delivered else { throw WatchMarginStoreError.unsyncedAudio(captureId) }
        try store.remove(captureId)
        entries.removeValue(forKey: captureId)
    }

    @discardableResult
    private func update(_ captureId: String, _ change: (inout Entry) -> Void) throws -> Entry {
        guard var entry = entries[captureId] else { throw WatchMarginStoreError.unknownCapture(captureId) }
        change(&entry)
        try store.write(captureId, entry: entry)
        entries[captureId] = entry
        return entry
    }
}

/// The phone's durable inbox of Margins recorded on the Watch (#788).
///
/// A transfer is checked against its metadata and stored before the receipt goes back, so the
/// Watch only lets go of bytes the phone holds. A capture is imported once however often it
/// arrives. A failed transcription keeps the original audio for another try.
public final class WatchMarginInbox {
    public struct Entry: Codable, Equatable, Sendable {
        public enum State: String, Codable, Equatable, Sendable {
            case awaitingTranscription
            case transcriptionFailed
            /// Transcribed and saved as a Margin.
            case incorporated
        }

        public var metadata: WatchMarginTransferMetadata
        public var state: State
        public var transcriptionAttempts: Int
        public var lastError: String?
        /// The Margin made from it, once incorporated.
        public var marginId: String?

        /// The id the Margin made from this capture must use. It depends only on the capture, so
        /// if the phone stops after saving the Margin but before `markIncorporated`, the retry
        /// saves over the same Margin instead of making a second one.
        public var marginIdToUse: String { "watch-margin-\(metadata.captureId)" }

        public var captureId: String { metadata.captureId }
        var audioFileName: String { "audio.\(metadata.audioFileExtension)" }
    }

    private let store: WatchMarginFolderStore<Entry>
    private var entries: [String: Entry]

    public init(directory: URL) throws {
        store = try WatchMarginFolderStore(directory: directory)
        entries = try store.loadAll()
    }

    public func entry(_ captureId: String) -> Entry? {
        entries[captureId]
    }

    /// The stored original recording.
    public func audioURL(_ captureId: String) -> URL? {
        guard let entry = entries[captureId] else { return nil }
        return store.folder(captureId).appendingPathComponent(entry.audioFileName)
    }

    /// Captures that still need a transcription, failed ones included, oldest first.
    public var needingTranscription: [Entry] {
        entries.values.filter { $0.state != .incorporated }.sorted { ($0.metadata.recordedAt, $0.captureId) < ($1.metadata.recordedAt, $1.captureId) }
    }

    /// Checks and stores a received file. The receipt goes back to the Watch.
    public func receive(file: URL, metadata: WatchMarginTransferMetadata) throws -> WatchMarginReceipt {
        try WatchMarginFolderStore<Entry>.validate(metadata.captureId)
        try WatchMarginFolderStore<Entry>.validate(fileExtension: metadata.audioFileExtension)
        if let existing = entries[metadata.captureId] {
            // Already stored: never import twice. Only the same bytes count as delivered.
            let status: WatchMarginReceipt.Status = existing.metadata.sha256 == metadata.sha256 ? .duplicate : .checksumMismatch
            return WatchMarginReceipt(captureId: metadata.captureId, sha256: existing.metadata.sha256, status: status)
        }
        let (byteCount, sha256) = try WatchMarginFolderStore<Entry>.digest(of: file)
        guard byteCount == metadata.byteCount else {
            return WatchMarginReceipt(captureId: metadata.captureId, sha256: sha256, status: .incomplete)
        }
        guard sha256 == metadata.sha256 else {
            return WatchMarginReceipt(captureId: metadata.captureId, sha256: sha256, status: .checksumMismatch)
        }
        let entry = Entry(metadata: metadata, state: .awaitingTranscription, transcriptionAttempts: 0, lastError: nil, marginId: nil)
        try store.commit(metadata.captureId, audio: file, audioFileName: entry.audioFileName, entry: entry)
        entries[metadata.captureId] = entry
        return WatchMarginReceipt(captureId: metadata.captureId, sha256: sha256, status: .stored)
    }

    /// The Margin was saved under the entry's `marginIdToUse`. Returns false if this capture was
    /// already incorporated, so the caller doesn't make a second one.
    @discardableResult
    public func markIncorporated(_ captureId: String) throws -> Bool {
        guard let entry = entries[captureId] else { throw WatchMarginStoreError.unknownCapture(captureId) }
        guard entry.state != .incorporated else { return false }
        try update(captureId) { entry in
            entry.state = .incorporated
            entry.transcriptionAttempts += 1
            entry.lastError = nil
            entry.marginId = entry.marginIdToUse
        }
        return true
    }

    /// Transcription failed. The original audio stays for a retry.
    public func markTranscriptionFailed(_ captureId: String, reason: String) throws {
        try update(captureId) { entry in
            guard entry.state != .incorporated else { return }
            entry.state = .transcriptionFailed
            entry.transcriptionAttempts += 1
            entry.lastError = reason
        }
    }

    private func update(_ captureId: String, _ change: (inout Entry) -> Void) throws {
        guard var entry = entries[captureId] else { throw WatchMarginStoreError.unknownCapture(captureId) }
        change(&entry)
        try store.write(captureId, entry: entry)
        entries[captureId] = entry
    }
}
