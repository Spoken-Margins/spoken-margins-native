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
/// the final name.
public struct PDFOriginalStore: Sendable {
    public static let fileName = "original.pdf"
    private static let temporarySuffix = ".tmp"

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
            try data.write(to: temporary)
            // rename(2) replaces an existing file in one step on the same volume. (`FileManager.replaceItemAt` has
            // left no file at the destination on Linux, so it is not used.)
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        clearTemporaryFiles(in: folder)
        return destination
    }

    /// The item's kept PDF, or nil when this iPhone has none (an item added before the copy was kept, or synced from another
    /// iPhone) or the item has no id.
    public func url(itemId: String) -> URL? {
        guard let folder = folderURL(itemId: itemId) else { return nil }
        let file = folder.appendingPathComponent(Self.fileName)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && !isDirectory.boolValue ? file : nil
    }

    /// The SHA-256 of the kept file, as lower-case hex; nil when there is none or it can't be read.
    public func sha256(itemId: String) -> String? {
        guard let file = url(itemId: itemId), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return SourceCatalogVerifier.sha256(data)
    }

    /// Removes the item's folder and the PDF in it. Nothing to remove is not an error.
    public func remove(itemId: String) throws {
        guard let folder = folderURL(itemId: itemId), FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Clears temporary files a quit left behind, in every item's folder, and returns how many it removed. Never touches a
    /// kept PDF. Run it at launch.
    @discardableResult
    public func removeInterruptedWrites() -> Int {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        return folders.reduce(0) { $0 + clearTemporaryFiles(in: $1) }
    }

    /// The folder an item's original lives in, nil for an empty id.
    public func folderURL(itemId: String) -> URL? {
        guard let name = ItemOwnedFiles.itemOriginalsFolderName(itemId: itemId) else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    @discardableResult
    private func clearTemporaryFiles(in folder: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(Self.fileName + ".") && name.hasSuffix(Self.temporarySuffix) {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
