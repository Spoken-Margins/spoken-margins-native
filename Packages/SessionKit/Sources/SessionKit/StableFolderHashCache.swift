import Foundation

/// Hashes of model folders whose files don't change while they're in place (#2055 audit 4): the app bundle,
/// and a downloaded voice, whose files were each held to their SHA-256 when it was installed. A folder under
/// one of `stableRoots` is hashed once and the hash is kept until `forget(under:)` is called for it, which the
/// app does whenever a voice is installed or removed. Any other folder (an import, a test fixture) is hashed
/// on every call, so an edit is always seen.
public final class StableFolderHashCache: @unchecked Sendable {
    private let lock = NSLock()
    private let stableRoots: [String]
    private var hashes: [String: String] = [:]
    /// Bumped by `forget`, so a hash computed while a voice was being removed or replaced isn't kept.
    private var generation = 0

    public init(stableRoots: [URL]) {
        self.stableRoots = stableRoots.map(Self.folderPath)
    }

    public func value(at folder: URL, compute: () throws -> String) rethrows -> String {
        let key = Self.folderPath(folder)
        guard stableRoots.contains(where: { key.hasPrefix($0) }) else { return try compute() }
        lock.lock()
        let cached = hashes[key]
        let started = generation
        lock.unlock()
        if let cached { return cached }
        let result = try compute()
        lock.lock()
        if generation == started { hashes[key] = result }
        lock.unlock()
        return result
    }

    /// Forgets every hash kept for a folder under `root`, and any hash being computed right now.
    public func forget(under root: URL) {
        let prefix = Self.folderPath(root)
        lock.lock()
        hashes = hashes.filter { !$0.key.hasPrefix(prefix) }
        generation += 1
        lock.unlock()
    }

    /// The folder's path with symlinks resolved and one trailing slash, so `/a/b` never matches `/a/bc`.
    private static func folderPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasSuffix("/") ? path : path + "/"
    }
}
