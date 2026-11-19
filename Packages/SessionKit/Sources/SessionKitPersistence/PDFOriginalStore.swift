import Foundation
import SessionKit

/// The original PDF the listener added, kept on the iPhone beside the item (#4338).
///
/// The import paths read a PDF's text and let the file go. Exporting the listener's Margins as comments in a copy of the
/// PDF needs the file itself, so from now on each PDF import keeps one here, under `ItemOriginals/<folder>/original.pdf`.
/// The folder is named by a digest of the item id (an id can hold a slash or collide once made safe, a digest cannot), and
/// `ItemOwnedFiles` names the same folder so a permanent delete removes it. Nothing writes here yet: the import paths
/// call it in a later change.
///
/// A write goes to a temporary file in the same folder and is then renamed over the final name, so a quit leaves either
/// the old file, the new file or a leftover temporary file that `removeInterruptedWrites` clears. Never a half file under
/// the final name. The data is synced to disk before the rename, so that also holds after a crash or a power loss.
///
/// Another write to the same item may be running (a double import, a re-import during a share import), so clearing
/// leftovers only touches temporary files untouched for `abandonedAfter` seconds, never one still being written.
public struct PDFOriginalStore: Sendable {
    public static let fileName = "original.pdf"
    private static let temporarySuffix = ".tmp"
    /// A temporary file this old belongs to a write that is no longer running.
    public static let abandonedAfter: TimeInterval = 600

    /// The `ItemOriginals` folder under Application Support.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public enum StoreError: Error, Equatable, Sendable {
        case noItemId
    }

    /// Keeps `data` as the item's original PDF, replacing the one it had. Returns the file's URL.
    @discardableResult
    public func write(_ data: Data, itemId: String) throws -> URL {
        guard let folder = folderURL(itemId: itemId) else { throw StoreError.noItemId }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.fileName)
        let temporary = folder.appendingPathComponent(Self.fileName + "." + UUID().uuidString + Self.temporarySuffix)
        do {
            try writeAndSync(data, to: temporary)
            // rename(2) replaces an existing file in one step on the same volume. (`FileManager.replaceItemAt` has
            // left no file at the destination on Linux, so it is not used.)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        clearTemporaryFiles(in: folder, olderThan: Self.abandonedAfter, now: Date())
        return destination
    }

    /// A copy of a picked file, made while its access is open and not yet the item's original. It is a temporary file in the
    /// item's folder (`removeInterruptedWrites` clears one left behind), so a batch of large PDFs holds file addresses and
    /// hashes, never the bytes. `commit` makes it the original once the item is saved; `discard` removes it.
    public struct Staged: Equatable, Sendable {
        public let itemId: String
        public let url: URL
        /// The SHA-256 of the staged bytes, lower-case hex: the value to record as `Extraction.sourceSHA256`.
        public let sha256: String
    }

    /// Copies `source` into a temporary file in the item's folder, a chunk at a time, and hashes it.
    public func stage(copying source: URL, itemId: String) throws -> Staged {
        guard let folder = folderURL(itemId: itemId) else { throw StoreError.noItemId }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(Self.fileName + "." + UUID().uuidString + Self.temporarySuffix)
        do {
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            return Staged(itemId: itemId, url: temporary, sha256: try SourceCatalogVerifier.sha256(ofFileAt: temporary))
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Makes a staged file the item's original, replacing the one it had. Returns the file's URL.
    @discardableResult
    public func commit(_ staged: Staged) throws -> URL {
        guard let folder = folderURL(itemId: staged.itemId) else { throw StoreError.noItemId }
        let destination = folder.appendingPathComponent(Self.fileName)
        guard rename(staged.url.path, destination.path) == 0 else {
            let reason = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staged.url)
            throw reason
        }
        clearTemporaryFiles(in: folder, olderThan: Self.abandonedAfter, now: Date())
        return destination
    }

    /// Removes a staged file that will not become an original (its item did not save). Nothing to remove is not an error.
    public func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.url)
    }

    /// The item's kept PDF, or nil when this iPhone has none (an item added before the copy was kept, or synced from another
    /// iPhone) or the item has no id.
    public func url(itemId: String) -> URL? {
        guard let folder = folderURL(itemId: itemId) else { return nil }
        let file = folder.appendingPathComponent(Self.fileName)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue ? file : nil
    }

    /// The SHA-256 of PDF bytes as lower-case hex: what an import records as `Extraction.sourceSHA256` before it saves the
    /// item, and what `sha256(itemId:)` reads back from the kept file, so the two can be compared.
    public static func sha256(of data: Data) -> String {
        SourceCatalogVerifier.sha256(data)
    }

    /// The SHA-256 of the kept file, as lower-case hex; nil when there is none or it can't be read.
    public func sha256(itemId: String) -> String? {
        guard let file = url(itemId: itemId), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return Self.sha256(of: data)
    }

    /// Removes the item's folder and the PDF in it. Nothing to remove is not an error.
    public func remove(itemId: String) throws {
        guard let folder = folderURL(itemId: itemId), FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Clears temporary files a quit left behind, in every item's folder, and returns how many it removed. Never touches a
    /// kept PDF. Run it at launch.
    @discardableResult
    public func removeInterruptedWrites(olderThan age: TimeInterval = PDFOriginalStore.abandonedAfter, now: Date = Date()) -> Int {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return folders.reduce(0) { $0 + clearTemporaryFiles(in: $1, olderThan: age, now: now) }
    }

    /// The folder an item's original lives in, nil for an empty id.
    public func folderURL(itemId: String) -> URL? {
        guard let name = ItemOwnedFiles.itemOriginalsFolderName(itemId: itemId) else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Writes `data` to a new file and flushes it to disk, so a rename that follows can't leave an empty file after a crash.
    private func writeAndSync(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Removes temporary files last changed at least `age` seconds before `now`.
    @discardableResult
    private func clearTemporaryFiles(in folder: URL, olderThan age: TimeInterval, now: Date) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(Self.fileName + ".") && name.hasSuffix(Self.temporarySuffix) {
            let file = folder.appendingPathComponent(name)
            guard let changed = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) >= age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
