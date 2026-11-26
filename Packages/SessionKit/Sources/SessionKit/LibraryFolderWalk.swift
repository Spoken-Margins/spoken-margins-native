#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Reads a picked folder into the ordered list of things a Library folder will hold (#3769). It decides which files are
/// supported, in what order, and what is left out and why; it imports nothing and keeps no state. Files are streamed through
/// SHA-256 so the folder's record can tell "the same file again" from "a changed file" later.
///
/// Bounds: 4 levels of subfolders, 2,000 entries listed in all, and the first 200 supported files (a link list counts as one;
/// its entries do not count). Subfolders are flattened into the one folder. Hidden files and packages are skipped, except an
/// iCloud placeholder (`.Name.pdf.icloud`), which is read as `Name.pdf` and marked not downloaded. A `.spokenmargins` file or
/// package is checked before the package skip and named, never imported.
public enum LibraryFolderWalk {
    public static let defaultMaxDepth = 4
    public static let defaultMaxEntries = 2_000
    public static let defaultMaxFiles = 200

    public enum Kind: String, Codable, Equatable, Sendable {
        case pdf, text, markdown, epub, audio
        /// A Listening Edition `.json`.
        case edition
        /// One entry of a link list: `key` is `list.json#001`, `address` its https link.
        case link
    }

    public struct Member: Equatable, Sendable {
        /// The relative path in NFC, or `path#NNN` for a link-list entry (NNN from 001, in the list's order).
        public var key: String
        public var kind: Kind
        /// Bytes on disk; 0 for a link entry and for a placeholder.
        public var size: Int64
        /// Hex SHA-256 of the file's bytes. Nil for a link entry (its identity is its address) and for a placeholder.
        public var sha256: String?
        /// Where the file is. For a placeholder, the real name the file will have once downloaded. Nil for a link entry.
        public var url: URL?
        /// The https address of a link entry.
        public var address: String?
        /// The entry's own title, for a link entry.
        public var title: String?
        /// An iCloud file that is not on the device yet. The caller asks the system to download it.
        public var isNotDownloaded: Bool
    }

    /// Something in the folder that will not be added, with the reason the listener is shown under "Couldn't add".
    public struct NotAdded: Equatable, Sendable {
        public var key: String
        public var name: String
        public var reason: String
    }

    public struct Result: Equatable, Sendable {
        /// In folder order, at most `maxFiles` files, with each link list's entries in place.
        public var members: [Member]
        public var notAdded: [NotAdded]
        /// Files of kinds the app can't read (images and the like): counted, not named.
        public var skippedOtherCount: Int
        /// More supported files were found than `maxFiles`.
        public var filesCapped: Bool
        /// The listing stopped at `maxEntries`, so some of the folder was never looked at.
        public var entriesCapped: Bool
        /// There are folders more than `maxDepth` levels down, which were not entered.
        public var hasDeeperFolders: Bool
    }

    public static let packetReason = "Margins packets open on their own"
    public static let unreadableJSONReason = "Not a file the app can read"

    private struct Candidate {
        var key: String
        var url: URL
        var kind: Kind
        var isJSON: Bool
        var placeholder: Bool
    }

    public static func walk(
        _ folder: URL,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries,
        maxFiles: Int = defaultMaxFiles
    ) -> Result {
        var candidates: [Candidate] = []
        var notAdded: [NotAdded] = []
        var skippedOther = 0
        var entryCount = 0
        var entriesCapped = false
        var deeper = false

        func walkDirectory(_ directory: URL, relative: [String], depth: Int) {
            guard !entriesCapped,
                  let children = try? FileManager.default.contentsOfDirectory(
                      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])
            else { return }
            let sorted = children.sorted { NaturalPathOrder.areInIncreasingOrder($0.lastPathComponent, $1.lastPathComponent) }
            var subfolders: [(URL, String)] = []
            for child in sorted {
                if entryCount >= maxEntries { entriesCapped = true; return }
                let name = child.lastPathComponent
                var realName = name
                var isPlaceholder = false
                if name.hasPrefix(".") {
                    // `.Name.pdf.icloud` is a file that is not downloaded; every other hidden entry is skipped.
                    guard name.hasSuffix(".icloud"), name.count > ".x.icloud".count else { continue }
                    realName = String(name.dropFirst().dropLast(".icloud".count))
                    isPlaceholder = true
                }
                entryCount += 1
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDirectory = values?.isDirectory == true
                let nfcRelative = (relative + [realName]).map { $0.precomposedStringWithCanonicalMapping }.joined(separator: "/")
                let ext = (realName as NSString).pathExtension.lowercased()
                // A Margins packet is named before the package skip, as a file or as a package folder.
                if ext == "spokenmargins" {
                    notAdded.append(NotAdded(key: nfcRelative, name: realName, reason: packetReason))
                    continue
                }
                if isDirectory {
                    if isPackage(values) { continue }
                    if depth < maxDepth { subfolders.append((child, realName)) } else { deeper = true }
                    continue
                }
                guard let kind = kind(forExtension: ext) else { skippedOther += 1; continue }
                candidates.append(Candidate(key: nfcRelative, url: child, kind: kind.kind, isJSON: kind.isJSON, placeholder: isPlaceholder))
            }
            for (sub, name) in subfolders {
                walkDirectory(sub, relative: relative + [name], depth: depth + 1)
                if entriesCapped { return }
            }
        }
        walkDirectory(folder, relative: [], depth: 0)

        candidates.sort { NaturalPathOrder.areInIncreasingOrder($0.key, $1.key) }
        let kept = Array(candidates.prefix(maxFiles))
        var members: [Member] = []
        for candidate in kept {
            if candidate.isJSON {
                members.append(contentsOf: jsonMembers(candidate, notAdded: &notAdded))
            } else {
                members.append(fileMember(candidate, kind: candidate.kind))
            }
        }
        return Result(members: members, notAdded: notAdded, skippedOtherCount: skippedOther,
                      filesCapped: candidates.count > maxFiles, entriesCapped: entriesCapped, hasDeeperFolders: deeper)
    }

    /// A bundle such as `Thing.app`, which is not entered. Only Apple platforms know; elsewhere Foundation calls any folder
    /// with a dot in its name a package, which would drop "Disc 1.5".
    private static func isPackage(_ values: URLResourceValues?) -> Bool {
        #if canImport(Darwin)
        return values?.isPackage == true
        #else
        return false
        #endif
    }

    // MARK: - Classifying

    /// A `.json` is decided by its content later; `kind` is a placeholder for it.
    private static func kind(forExtension ext: String) -> (kind: Kind, isJSON: Bool)? {
        switch ext {
        case "pdf": return (.pdf, false)
        case "txt": return (.text, false)
        case "md", "markdown": return (.markdown, false)
        case "epub": return (.epub, false)
        case "mp3", "m4a", "m4b", "mp4": return (.audio, false)
        case "json": return (.edition, true)
        default: return nil
        }
    }

    private static func fileMember(_ candidate: Candidate, kind: Kind) -> Member {
        if candidate.placeholder {
            return Member(key: candidate.key, kind: kind, size: 0, sha256: nil, url: realURL(of: candidate.url),
                          address: nil, title: nil, isNotDownloaded: true)
        }
        let hashed = hash(of: candidate.url)
        return Member(key: candidate.key, kind: kind, size: hashed?.size ?? 0, sha256: hashed?.sha256, url: candidate.url,
                      address: nil, title: nil, isNotDownloaded: notDownloaded(candidate.url))
    }

    private static func jsonMembers(_ candidate: Candidate, notAdded: inout [NotAdded]) -> [Member] {
        let name = (candidate.key as NSString).lastPathComponent
        if candidate.placeholder {
            // Its content is unknown until it is downloaded, so it cannot be told apart from another `.json` yet.
            return [Member(key: candidate.key, kind: .edition, size: 0, sha256: nil, url: realURL(of: candidate.url),
                           address: nil, title: nil, isNotDownloaded: true)]
        }
        guard let data = readPrefix(of: candidate.url, maxBytes: LinkListFile.maxFileBytes + 1) else {
            notAdded.append(NotAdded(key: candidate.key, name: name, reason: unreadableJSONReason))
            return []
        }
        switch LinkListFile.recognize(data) {
        case .linkList(let list):
            return linkMembers(of: list, at: candidate.key, notAdded: &notAdded)
        case .rejected(let message):
            notAdded.append(NotAdded(key: candidate.key, name: name, reason: message))
            return []
        case .notALinkList:
            guard isEdition(data) else {
                notAdded.append(NotAdded(key: candidate.key, name: name, reason: unreadableJSONReason))
                return []
            }
            return [fileMember(candidate, kind: .edition)]
        }
    }

    /// A link list's entries as members, in the list's own order, and its skipped entries as "Couldn't add" rows.
    private static func linkMembers(of list: LinkListFile, at path: String, notAdded: inout [NotAdded]) -> [Member] {
        for skipped in list.skipped {
            notAdded.append(NotAdded(
                key: linkKey(path, position: skipped.position), name: skipped.text ?? "Entry \(skipped.position)",
                reason: skipped.text == nil ? skipped.reason : "is not added: \(skipped.reason)"))
        }
        // Entries keep the list's own order. The numbers count the entries that were kept, from 001. A follow entry (#4683)
        // is a show to suggest, not an item, so it is never a member.
        return list.entries.filter { !$0.follow }.enumerated().map { index, entry in
            Member(key: linkKey(path, position: index + 1), kind: .link, size: 0, sha256: nil, url: nil,
                   address: entry.url, title: entry.title, isNotDownloaded: false)
        }
    }

    /// One picked link list read as a folder holding only that list (#3769): its entries become link members exactly as
    /// they would inside a picked folder, so a titled list makes a collection through the same merge, and picking the
    /// same list again adds only its new links.
    public static func linkList(_ list: LinkListFile, named fileName: String) -> Result {
        var notAdded: [NotAdded] = []
        let members = linkMembers(of: list, at: fileName.precomposedStringWithCanonicalMapping, notAdded: &notAdded)
        return Result(members: members, notAdded: notAdded, skippedOtherCount: 0,
                      filesCapped: false, entriesCapped: false, hasDeeperFolders: false)
    }

    private static func linkKey(_ path: String, position: Int) -> String {
        "\(path)#" + String(format: "%03d", position)
    }

    /// An edition says so in its top-level `schemaVersion`. Whether it passes the edition's own checks is the importer's call.
    private static func isEdition(_ data: Data) -> Bool {
        if data.count <= LinkListFile.maxFileBytes {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return (object["schemaVersion"] as? String) == ListeningEdition.version
        }
        // Too big to parse whole here: look for the version text near the top.
        return data.prefix(4_096).range(of: Data("\"\(ListeningEdition.version)\"".utf8)) != nil
    }

    // MARK: - Files

    private static func realURL(of placeholder: URL) -> URL {
        let name = placeholder.lastPathComponent
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return placeholder.deletingLastPathComponent().appendingPathComponent(real)
    }

    private static func readPrefix(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    /// Streams the file through SHA-256 in 1 MB chunks, so a long audio file is never held in memory.
    private static func hash(of url: URL) -> (sha256: String, size: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// An iCloud file whose copy on the device is not current. Only Apple platforms can ask.
    private static func notDownloaded(_ url: URL) -> Bool {
        #if canImport(Darwin)
        guard let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        else { return false }
        return status != .current
        #else
        return false
        #endif
    }
}
