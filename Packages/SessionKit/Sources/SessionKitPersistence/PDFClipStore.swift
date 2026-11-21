import Foundation
import SessionKit

/// The pictures of a PDF's tables and figures, kept as files for the Timeline to show (#3895).
///
/// The PDF is not kept after it is imported, so each clip is cut from it at import and saved here, one JPEG per
/// float of the item's structured document, in a folder of the item's own: `<directory>/<item folder>/<float>.jpg`.
/// Nothing reads a clip until the listener opens that Timeline, or the Now tab on that item (one folder listing; a
/// clip is read when its card draws, #4588). A permanent delete removes the item's folder
/// (`ItemOwnedFiles.pdfClipsRoot`). A clip that isn't there is not an error: the row shows its text, as it always has.
public struct PDFClipStore: Sendable {
    /// `SpokenMargins/PDFClips/` under Application Support.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The file name of a float's clip, or nil when its id can't name a file.
    public static func fileName(forFloat floatId: String) -> String? {
        guard !floatId.isEmpty else { return nil }
        let name = PodcastAnchorEvidencePaths.safeComponent(floatId)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        return name + ".jpg"
    }

    /// The item's folder, or nil when the id has none of its own.
    public func folder(forItem itemId: String) -> URL? {
        ItemOwnedFiles.pdfClipDirectoryName(itemId: itemId).map { directory.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// The clip's file, if it was saved.
    public func url(forFloat floatId: String, itemId: String) -> URL? {
        guard let folder = folder(forItem: itemId), let name = Self.fileName(forFloat: floatId) else { return nil }
        let file = folder.appending(path: name)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Which floats of an item have a clip saved, read from one listing of the item's folder. The Timeline asks this
    /// once for the rows it may draw, so deciding whether a row has a picture costs no file check per row and decodes
    /// nothing. An item with no folder of its own, or no clips, has none.
    public struct Available: Equatable, Sendable {
        fileprivate let names: Set<String>
        /// When the item's clip folder was last replaced, in seconds since 1970; 0 when it has none. A re-import
        /// swaps the folder for a new one, so the same float ids can name different pictures: a reader that keeps
        /// what it decoded compares this to know the files changed under it.
        public let stamp: Double

        public static let none = Available(names: [], stamp: 0)

        public var isEmpty: Bool { names.isEmpty }

        public func contains(floatId: String?) -> Bool {
            guard let floatId, let name = PDFClipStore.fileName(forFloat: floatId) else { return false }
            return names.contains(name)
        }
    }

    /// Posted on the main actor after an import has saved an item's clips (or cleared them). `userInfo[itemIdKey]` is
    /// the item's id as a `String`. A screen that listed the clips earlier lists them again for that item.
    public static let didSaveClipsNotification = Notification.Name("SpokenMargins.PDFClipStore.didSaveClips")
    public static let itemIdKey = "itemId"

    /// Which of `floatIds` have a clip saved for the item, from one listing of its folder: no clip file is opened. A
    /// missing folder, or an item with no folder of its own, gives the empty set.
    public func savedFloatIds(forItem itemId: String, among floatIds: [String]) -> Set<String> {
        let available = available(forItem: itemId)
        guard !available.isEmpty else { return [] }
        return Set(floatIds.filter { available.contains(floatId: $0) })
    }

    public func available(forItem itemId: String) -> Available {
        guard let folder = folder(forItem: itemId),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return .none }
        let modified = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
        return Available(names: Set(names.filter { $0.hasSuffix(".jpg") }), stamp: modified?.timeIntervalSince1970 ?? 0)
    }

    /// The saved JPEG of a float's clip, or nil when there is none or it can't be read.
    public func data(forFloat floatId: String, itemId: String) -> Data? {
        url(forFloat: floatId, itemId: itemId).flatMap { try? Data(contentsOf: $0) }
    }

    /// Makes `clips` (JPEG data by float id) the item's clips, and nothing else. Only the floats of `document` get one:
    /// a clip whose float is not in the document the item now has could never be shown, so it is not kept. Clips
    /// the item had before are replaced, so a re-import leaves no stale picture. With none to keep, the folder goes.
    ///
    /// The new files are written beside the old folder and swapped in, so a failed write leaves the old clips.
    public func replaceClips(_ clips: [String: Data], forItem itemId: String, document: StructuredDocument?) throws {
        guard let folder = folder(forItem: itemId) else { return }
        let wanted = Set(document?.floats.map(\.id) ?? [])
        let files = clips.compactMap { id, data -> (name: String, data: Data)? in
            guard wanted.contains(id), !data.isEmpty, let name = Self.fileName(forFloat: id) else { return nil }
            return (name, data)
        }
        let manager = FileManager.default
        guard !files.isEmpty else {
            if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
            return
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appending(path: ".\(folder.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .isDirectory)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in files { try file.data.write(to: staging.appending(path: file.name), options: .atomic) }
            if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
            try manager.moveItem(at: staging, to: folder)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Removes the item's clips.
    public func removeClips(forItem itemId: String) throws {
        guard let folder = folder(forItem: itemId), FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
