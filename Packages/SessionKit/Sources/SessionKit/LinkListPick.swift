import Foundation

/// What a pick of `.json` files, and of folders that may hold them, contains once each file has been sorted by its own
/// `schemaVersion` (#3767): link lists, files that said they were link lists but can't be taken (with the reason), and
/// every other `.json` file, which goes to the Listening Edition import exactly as before.
///
/// Only the file's content decides, never its name or the folder it sits in. Reading happens here, with real files, so
/// it can be tested on the host; the app calls `sort` off the main thread.
public struct LinkListPick: Sendable {
    public struct Found: Sendable {
        public let name: String
        public let list: LinkListFile
        public init(name: String, list: LinkListFile) {
            self.name = name
            self.list = list
        }
    }

    public struct Rejection: Sendable {
        public let name: String
        public let message: String
        public init(name: String, message: String) {
            self.name = name
            self.message = message
        }
    }

    /// Link lists, picked files first (in pick order), then folder files in the folder walk's order.
    public var lists: [Found] = []
    public var rejections: [Rejection] = []
    /// Picked files (not from a folder) that are not link lists. A file that can't be read is here too, so the edition
    /// import reports it the way it always did.
    public var others: [URL] = []
    /// `filePath` of every folder file that was a link list or a rejected one. The edition import skips these.
    public var folderFilePaths: Set<String> = []
    /// How many `.json` files found in folders are not link lists. The edition import still takes these.
    public var folderOtherCount = 0
    /// True when a folder held more `.json` files than the walk reads.
    public var folderTruncated = false

    public init() {}

    /// Nothing in the pick said it was a link list.
    public var isEmpty: Bool { lists.isEmpty && rejections.isEmpty }

    /// Whether the Listening Edition import still has something to do. A folder holding only link lists leaves it
    /// nothing, and the "no collection files" message would be wrong; a folder with no `.json` at all still gets it.
    public func needsEditionImport(foldersPicked: Bool) -> Bool {
        if !others.isEmpty { return true }
        guard foldersPicked else { return false }
        return folderOtherCount > 0 || folderFilePaths.isEmpty
    }

    /// The key `folderFilePaths` uses, so the edition import can match a walked file to a sorted one.
    public static func filePath(_ url: URL) -> String { url.standardizedFileURL.path }

    /// A file bigger than this is never read here: it could still be a Listening Edition (up to 8 MB), which the
    /// edition import reads itself, and a link list is far smaller. `LinkListFile.recognize` refuses an oversized list
    /// on its own, so the cap only keeps a huge file out of memory.
    public static let maxReadBytes = 8_000_000

    /// Sorts the picked files and the `.json` files found in the picked folders. A folder's security-scoped access stays
    /// open while its files are read, since the files inherit it.
    public static func sort(files: [URL],
                            folders: [URL] = [],
                            maxFolderFiles: Int = ListeningEditionFolderWalk.defaultMaxFiles) -> LinkListPick {
        var pick = LinkListPick()
        for url in files {
            switch classify(url) {
            case .other: pick.others.append(url)
            case .list(let list): pick.lists.append(Found(name: url.lastPathComponent, list: list))
            case .rejected(let message): pick.rejections.append(Rejection(name: url.lastPathComponent, message: message))
            }
        }
        var scoped: [URL] = []
        defer { for folder in scoped { stopAccess(folder) } }
        var walkedCount = 0
        for folder in folders {
            if startAccess(folder) { scoped.append(folder) }
            let walked = ListeningEditionFolderWalk.collect(in: folder, maxFiles: max(0, maxFolderFiles - walkedCount))
            walkedCount += walked.urls.count
            if walked.truncated { pick.folderTruncated = true }
            for url in walked.urls {
                switch classify(url) {
                case .other:
                    pick.folderOtherCount += 1
                case .list(let list):
                    pick.folderFilePaths.insert(filePath(url))
                    pick.lists.append(Found(name: url.lastPathComponent, list: list))
                case .rejected(let message):
                    pick.folderFilePaths.insert(filePath(url))
                    pick.rejections.append(Rejection(name: url.lastPathComponent, message: message))
                }
            }
        }
        return pick
    }

    private enum Kind { case other, list(LinkListFile), rejected(String) }

    private static func classify(_ url: URL) -> Kind {
        guard let data = fileData(url) else { return .other }
        switch LinkListFile.recognize(data) {
        case .notALinkList: return .other
        case .linkList(let list): return .list(list)
        case .rejected(let message): return .rejected(message)
        }
    }

    /// The file's bytes, or nil when it can't be read or is too big to be a link list or an edition.
    private static func fileData(_ url: URL) -> Data? {
        let accessed = startAccess(url)
        defer { if accessed { stopAccess(url) } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxReadBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    // Security-scoped access exists only on Apple platforms; the host tests on Linux read plain files.
    private static func startAccess(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    private static func stopAccess(_ url: URL) {
        #if canImport(Darwin)
        url.stopAccessingSecurityScopedResource()
        #endif
    }
}
