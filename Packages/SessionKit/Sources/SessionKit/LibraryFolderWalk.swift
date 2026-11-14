import CryptoKit
import Foundation

/// Lists what a picked folder would bring into the Library as one folder (#3769), in the order it should play.
///
/// This is PR 1 of the folder plan: it only reads. It decides what each file is, orders them with
/// `NaturalPathOrder`, keeps at most `maxFiles`, and streams a SHA-256 for each file it keeps so a later import can
/// tell "the same file again" from "an updated copy". It never copies, imports or modifies anything, so it can run
/// on any thread; the app calls it from a detached task, never the main actor.
///
/// Rules, from the design on #3769:
/// - PDF, text, Markdown, EPUB, MP3/M4A/M4B/MP4 audio, Listening Edition `.json` and link-list `.json` are members.
///   A `.json` is classified by its content, never its name. A link list expands into one member per link, at the
///   list file's place, and those links do not count toward `maxFiles`.
/// - Up to `maxDepth` levels of subfolders are read, and at most `maxEntries` entries are listed in all.
/// - Subfolders are flattened into the one folder. Hidden files and packages are skipped, except iCloud
///   placeholders (`.Name.pdf.icloud`), which are listed as `Name.pdf` and marked not downloaded yet.
/// - `.spokenmargins` packets are never members. They are named in `packets`.
/// - Images and other files are counted in `skippedOthers`, not listed.
public enum LibraryFolderWalk {
    public static let defaultMaxFiles = 200
    public static let defaultMaxDepth = 4
    public static let defaultMaxEntries = 2_000
    /// A `.json` larger than this is not read to be classified; it is named as unreadable.
    public static let maxJSONBytes = 8_000_000

    public enum Kind: String, Equatable, Sendable {
        case pdf, text, markdown, epub, audio
        /// A Listening Edition `.json`.
        case edition
        /// One link out of a link-list `.json` (#3767). `Member.linkURL` holds the address.
        case link
        /// A `.json` that is not downloaded yet, so its content can't be read. It is classified once it arrives.
        case json
    }

    public enum Availability: Equatable, Sendable {
        case local
        /// An iCloud placeholder, or a file whose current version is not on the device. It has no hash yet.
        case notDownloaded
    }

    public struct Member: Equatable, Sendable {
        /// Identity inside the folder: the path relative to the folder, or `path#NNN` for a link-list entry.
        public let key: String
        public let kind: Kind
        /// The file to import. For a link entry, the link-list file it came from. For a placeholder, the
        /// `.Name.icloud` file as it sits on disk.
        public let url: URL
        public let size: Int64?
        /// Lower-case hex SHA-256 of the file's bytes. Nil for link entries and for files not downloaded yet.
        public let sha256: String?
        public let availability: Availability
        /// The address of a `.link` member; nil otherwise.
        public let linkURL: String?
        public let linkTitle: String?

        public init(key: String, kind: Kind, url: URL, size: Int64?, sha256: String?,
                    availability: Availability = .local, linkURL: String? = nil, linkTitle: String? = nil) {
            self.key = key; self.kind = kind; self.url = url; self.size = size; self.sha256 = sha256
            self.availability = availability; self.linkURL = linkURL; self.linkTitle = linkTitle
        }
    }

    /// A file or link the walk found but the app can't take, with the reason to show the listener.
    public struct Problem: Equatable, Sendable {
        public let key: String
        public let reason: String
        public init(key: String, reason: String) { self.key = key; self.reason = reason }
    }

    public struct Result: Equatable, Sendable {
        /// In playing order, at most `maxFiles` files plus the links of any link lists among them.
        public let members: [Member]
        /// Images and other files the app doesn't read. Counted, not listed.
        public let skippedOthers: Int
        /// Relative paths of `.spokenmargins` packets. They are named under "Couldn't add".
        public let packets: [String]
        /// Link lists that were refused, `.json` files that are neither a link list nor an edition, and link
        /// entries a list had but the app won't add.
        public let problems: [Problem]
        /// True when more supported files were found than `maxFiles`.
        public let truncated: Bool
        /// True when the walk stopped after `maxEntries` entries, so later files were never looked at.
        public let entryLimitReached: Bool
        /// True when the picked folder itself could not be listed.
        public let folderUnreadable: Bool

        public var placeholders: [Member] { members.filter { $0.availability == .notDownloaded } }

        public init(members: [Member], skippedOthers: Int, packets: [String], problems: [Problem],
                    truncated: Bool, entryLimitReached: Bool, folderUnreadable: Bool = false) {
            self.members = members; self.skippedOthers = skippedOthers; self.packets = packets
            self.problems = problems; self.truncated = truncated
            self.entryLimitReached = entryLimitReached; self.folderUnreadable = folderUnreadable
        }
    }

    public static func walk(_ folder: URL,
                            maxFiles: Int = defaultMaxFiles,
                            maxDepth: Int = defaultMaxDepth,
                            maxEntries: Int = defaultMaxEntries) -> Result {
        var state = State(maxFiles: maxFiles, maxDepth: maxDepth, maxEntries: maxEntries)
        let readable = state.visit(folder, prefix: "", depth: 0)
        return Result(members: state.members, skippedOthers: state.skippedOthers, packets: state.packets,
                      problems: state.problems, truncated: state.truncated,
                      entryLimitReached: state.entryLimitReached, folderUnreadable: !readable)
    }

    /// Lower-case hex SHA-256 of a file, read in 1 MiB pieces so a large audio file is never held in memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let piece = try handle.read(upToCount: 1 << 20) ?? Data()
            if piece.isEmpty { break }
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Walk state

    private struct State {
        let maxFiles: Int
        let maxDepth: Int
        let maxEntries: Int
        var members: [Member] = []
        var problems: [Problem] = []
        var packets: [String] = []
        var skippedOthers = 0
        var supportedCount = 0
        var entryCount = 0
        var truncated = false
        var entryLimitReached = false
        var stopped = false

        private static let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey,
        ]

        /// Returns false when `directory` could not be listed.
        mutating func visit(_ directory: URL, prefix: String, depth: Int) -> Bool {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Self.keys, options: []) else { return false }
            var named: [(url: URL, name: String, placeholder: Bool)] = []
            for child in children {
                let raw = child.lastPathComponent
                if raw.hasPrefix(".") {
                    // `.Name.pdf.icloud` is a file that lives in iCloud and has not been downloaded.
                    if raw.hasSuffix(".icloud"), raw.count > ".icloud".count + 1 {
                        named.append((child, String(raw.dropFirst().dropLast(".icloud".count)), true))
                    }
                    continue
                }
                named.append((child, raw, false))
            }
            named.sort { NaturalPathOrder.areInOrder($0.name, $1.name) }
            for item in named {
                if stopped { return true }
                entryCount += 1
                if entryCount > maxEntries { entryLimitReached = true; stopped = true; return true }
                handle(item.url, name: item.name, placeholder: item.placeholder, prefix: prefix, depth: depth)
            }
            return true
        }

        private mutating func handle(_ url: URL, name: String, placeholder: Bool, prefix: String, depth: Int) {
            let key = prefix + name
            let values = try? url.resourceValues(forKeys: Set(Self.keys))
            let ext = (name as NSString).pathExtension.lowercased()
            // Checked before the package skip: a packet is often a package, and it must be named, not dropped.
            if ext == "spokenmargins" { packets.append(key); return }
            if values?.isDirectory == true {
                if values?.isPackage == true { return }
                if depth < maxDepth { _ = visit(url, prefix: key + "/", depth: depth + 1) }
                return
            }
            let size = values?.fileSize.map(Int64.init)
            var availability: Availability = placeholder ? .notDownloaded : .local
            if let status = values?.ubiquitousItemDownloadingStatus, status != .current { availability = .notDownloaded }

            let kind: Kind
            switch ext {
            case "pdf": kind = .pdf
            case "txt", "text": kind = .text
            case "md", "markdown": kind = .markdown
            case "epub": kind = .epub
            case "mp3", "m4a", "m4b", "mp4": kind = .audio
            case "json":
                if availability == .notDownloaded { kind = .json } else { return handleJSON(url, key: key, size: size) }
            default:
                skippedOthers += 1
                return
            }
            addFile(Member(key: key, kind: kind, url: url, size: size, sha256: Self.hash(url, availability),
                           availability: availability))
        }

        private mutating func handleJSON(_ url: URL, key: String, size: Int64?) {
            guard let size, size <= Int64(LibraryFolderWalk.maxJSONBytes),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                problems.append(Problem(key: key, reason: "Not a file the app can read"))
                return
            }
            switch LinkListFile.recognize(data) {
            case .linkList(let list):
                for (index, entry) in list.entries.enumerated() {
                    members.append(Member(key: key + "#" + String(format: "%03d", index + 1), kind: .link, url: url,
                                          size: nil, sha256: nil, linkURL: entry.url, linkTitle: entry.title))
                }
                for skipped in list.skipped {
                    let what = skipped.text ?? "Entry \(skipped.position)"
                    problems.append(Problem(key: key + "#" + String(format: "%03d", skipped.position),
                                            reason: "\(what) \(skipped.reason)"))
                }
            case .rejected(let message):
                problems.append(Problem(key: key, reason: message))
            case .notALinkList:
                let version = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["schemaVersion"] as? String
                if version == ListeningEdition.version {
                    addFile(Member(key: key, kind: .edition, url: url, size: size, sha256: Self.hash(url, .local)))
                } else {
                    problems.append(Problem(key: key, reason: "Not a file the app can read"))
                }
            }
        }

        /// Adds a file member, or stops the walk when this would be file number `maxFiles + 1`.
        private mutating func addFile(_ member: @autoclosure () -> Member) {
            if supportedCount >= maxFiles { truncated = true; stopped = true; return }
            supportedCount += 1
            members.append(member())
        }

        private static func hash(_ url: URL, _ availability: Availability) -> String? {
            availability == .local ? try? LibraryFolderWalk.sha256(of: url) : nil
        }
    }
}
