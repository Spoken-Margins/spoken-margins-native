import Foundation

/// The files behind a live-session photo Margin (#2708): where a photo waits before it is saved, where it lives once
/// a Margin names it, how it is removed, and the launch sweep for a file nothing names. Foundation only, so every rule
/// here is tested on Linux; the picture work (scaling, encoding, thumbnails) is `LiveSessionPhotoEncoder`.
///
/// The order the app follows, so a crash never costs the listener their words or leaves a picture nothing owns for long:
///
/// 1. The listener takes a picture. The encoder fits it, and `stage` writes it to the temporary folder.
/// 2. The listener saves the Margin. `commit` moves the file to `SpokenMargins/live-photos/<session>/<margin>.jpg`, and
///    only then is the Margin that names it saved. A failure here means the Margin is saved without a photo.
/// 3. The listener cancels. `discard` deletes the temporary file.
/// 4. A crash between 2's move and the Margin's save leaves a file under `live-photos/` that no Margin names. `sweep`,
///    once per launch and before any live-session controller opens, removes it.
///
/// A photo is never part of a packet, share link or manifest, and this type is not used by `SessionKitSharing`
/// (`LiveSessionPhotoTests` fails if that changes). Nothing here touches the SQLite store.
public struct LiveSessionPhotoStore: Sendable {
    /// Application Support: photo paths are relative to it ("SpokenMargins/live-photos/…").
    public let root: URL
    /// Where a taken photo waits until it is saved or cancelled. The app's temporary directory unless a test says otherwise.
    public let temporaryRoot: URL

    /// The folder name under `temporaryRoot` that holds staged photos, so the sweep clears only what is ours.
    static let stagingFolderName = "live-photo-staging"

    public init(root: URL, temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.root = root
        self.temporaryRoot = temporaryRoot
    }

    public enum StoreError: Error, Equatable, Sendable {
        /// The picture breaks `LiveSessionPhoto`'s rules (too large, no size, an extension that is not a photo's).
        case refusedByRules
        /// Nothing at the staged location (cleared by the system, or already committed).
        case stagedFileMissing
        /// A photo is already kept under that session and Margin; it is never overwritten.
        case alreadyKept
    }

    // MARK: Paths

    /// A path component for any id: the id itself when it is plain, else a cleaned id with a short hash so two ids
    /// never share one. The same rule as `LiveSessionCollection`'s file names, so a session's photo folder is named
    /// like its session file and a session file that cannot be read still says which folder is its.
    public static func component(for id: String) -> String {
        let name = LiveSessionCollection.fileName(for: id)
        return String(name.dropLast(".json".count))
    }

    /// "SpokenMargins/live-photos/<session>/<margin>.<ext>", relative to `root`.
    public static func relativePath(sessionId: String, marginId: String, fileExtension: String = "jpg") -> String {
        "\(LiveSessionPhoto.folder)/\(component(for: sessionId))/\(component(for: marginId)).\(fileExtension)"
    }

    var photosDirectory: URL {
        LiveSessionPhoto.folder.split(separator: "/").reduce(root) { $0.appending(path: String($1), directoryHint: .isDirectory) }
    }

    var stagingDirectory: URL {
        temporaryRoot.appending(path: Self.stagingFolderName, directoryHint: .isDirectory)
    }

    /// The file a kept photo lives in; nil when its path breaks the rules, so a damaged session file can't point outside.
    public func fileURL(for photo: LiveSessionPhoto) -> URL? {
        guard photo.isWithinRules else { return nil }
        return root.appending(path: photo.path)
    }

    /// True when the photo's file is on this device. False for a missing file, which is its own state (a restored
    /// backup without the folder, a deleted file): the Margin still plays and exports.
    public func fileExists(for photo: LiveSessionPhoto) -> Bool {
        guard let url = fileURL(for: photo) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    // MARK: Staging

    /// A taken, fitted photo waiting in the temporary folder.
    public struct Staged: Equatable, Sendable {
        public let url: URL
        public let widthPx: Int
        public let heightPx: Int
        public let byteCount: Int
        public let fileExtension: String
    }

    /// Writes an already fitted and encoded photo to the temporary folder. Refuses a picture over the caps: the encoder
    /// is meant to have fitted it, so this is the guard that keeps a bug there from filling the device.
    public func stage(data: Data, widthPx: Int, heightPx: Int, fileExtension: String = "jpg") throws -> Staged {
        let ext = fileExtension.lowercased()
        // `LiveSessionPhoto` is the one place the caps and the allowed extensions live.
        guard LiveSessionPhoto(
            path: Self.relativePath(sessionId: "s", marginId: "m", fileExtension: ext),
            widthPx: widthPx, heightPx: heightPx, byteCount: data.count
        ) != nil else { throw StoreError.refusedByRules }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let url = stagingDirectory.appending(path: "\(UUID().uuidString.lowercased()).\(ext)")
        try data.write(to: url, options: .atomic)
        return Staged(url: url, widthPx: widthPx, heightPx: heightPx, byteCount: data.count, fileExtension: ext)
    }

    /// Moves a staged photo to its place under the session and returns the reference the Margin keeps. Call it before
    /// saving the Margin that names it. On any error the staged file is left where it was, so the caller can `discard`
    /// it, and the Margin is saved without a photo.
    public func commit(_ staged: Staged, sessionId: String, marginId: String) throws -> LiveSessionPhoto {
        let path = Self.relativePath(sessionId: sessionId, marginId: marginId, fileExtension: staged.fileExtension)
        guard let photo = LiveSessionPhoto(path: path, widthPx: staged.widthPx, heightPx: staged.heightPx, byteCount: staged.byteCount) else {
            throw StoreError.refusedByRules
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staged.url.path) else { throw StoreError.stagedFileMissing }
        let destination = root.appending(path: path)
        guard !fileManager.fileExists(atPath: destination.path) else { throw StoreError.alreadyKept }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staged.url, to: destination)
        return photo
    }

    /// Cancel: the temporary file goes. Safe to call twice.
    public func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.url)
    }

    // MARK: Removing

    /// Deleting a Margin deletes its photo file, and the session's folder when that was its last photo.
    public func remove(_ photo: LiveSessionPhoto) {
        guard let url = fileURL(for: photo) else { return }
        try? FileManager.default.removeItem(at: url)
        Self.removeIfEmpty(url.deletingLastPathComponent())
    }

    /// Deleting or discarding a session deletes its folder and every photo in it.
    public func removeFolder(sessionId: String) {
        try? FileManager.default.removeItem(
            at: photosDirectory.appending(path: Self.component(for: sessionId), directoryHint: .isDirectory)
        )
    }

    private static func removeIfEmpty(_ directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
        if contents.isEmpty { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: The launch sweep

    /// What one sweep did, for a test or a log line.
    public struct SweepResult: Equatable, Sendable {
        /// Files removed from a session folder because no Margin names them.
        public var removedFiles: [String] = []
        /// Session folders left untouched because their session file could not be read.
        public var protectedFolders: [String] = []
        /// Staged files from an earlier launch that were cleared.
        public var clearedStaged = 0
        /// True when the sweep did nothing because it could not see the session store.
        public var skipped = false
    }

    /// Removes the files under `live-photos/` that no Margin names, from a crash between the move and the save. Run it
    /// once at launch, **before any live-session controller opens**, so it may also clean the folder of a session that
    /// is still running: nothing is staged or half-saved at that moment. It also clears staged photos left in the
    /// temporary folder.
    ///
    /// It never touches a folder whose session file it cannot read (the file may hold the Margins that name those
    /// photos), and does nothing at all when the session store itself cannot be listed. It only removes regular files
    /// directly inside a session folder: anything else it finds stays.
    ///
    /// - Parameter sessions: the sessions that read, from `LiveSessionCollection.loadAll()`.
    /// - Parameter collection: the store, only to find which session files exist but did not read.
    @discardableResult
    public func sweep(readable sessions: [LiveSession], in collection: LiveSessionCollection) -> SweepResult {
        var result = SweepResult()
        let fileManager = FileManager.default
        result.clearedStaged = clearStaged()

        guard fileManager.fileExists(atPath: photosDirectory.path) else { return result }
        guard let sessionFiles = try? fileManager.contentsOfDirectory(atPath: collection.directory.path) else {
            result.skipped = true
            return result
        }

        let readableStems = Set(sessions.map { Self.component(for: $0.id) })
        // A session file whose stem is not a readable session's is one we could not read: its folder is off limits.
        let unreadableStems = Set(
            sessionFiles.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }
        ).subtracting(readableStems)

        // Any path a Margin names counts, even one that breaks the rules or sits in another session's folder: only a
        // path nothing names is removed.
        let named = Set(sessions.flatMap(\.margins).compactMap { $0.photo?.path })

        guard let folders = try? fileManager.contentsOfDirectory(at: photosDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return result
        }
        for folderURL in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = folderURL.lastPathComponent
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if unreadableStems.contains(name) {
                result.protectedFolders.append(name)
                continue
            }
            guard let entries = try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = "\(LiveSessionPhoto.folder)/\(name)/\(entry.lastPathComponent)"
                guard !named.contains(relative) else { continue }
                if (try? fileManager.removeItem(at: entry)) != nil { result.removedFiles.append(relative) }
            }
            Self.removeIfEmpty(folderURL)
        }
        return result
    }

    /// Clears the temporary staging folder, whose contents belong to a launch that is over.
    private func clearStaged() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        var cleared = 0
        for file in files where (try? FileManager.default.removeItem(at: stagingDirectory.appending(path: file))) != nil {
            cleared += 1
        }
        return cleared
    }
}
