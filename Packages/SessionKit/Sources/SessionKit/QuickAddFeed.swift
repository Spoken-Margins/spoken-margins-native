import Foundation

/// A recent file in the Quick Folder the listener picked in Add Source (#955).
public struct QuickAccessFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let modifiedAt: Date
    public let modifiedAtDescription: String

    public init(id: String, name: String, relativePath: String, modifiedAt: Date, modifiedAtDescription: String) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.modifiedAtDescription = modifiedAtDescription
    }

    /// Stored in UserDefaults key `dismissedQuickAccessFilesV1`, so a change would un-dismiss files.
    public var dismissalKey: String {
        "\(id)|\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

/// One row of the Quick Add list on the Following tab: a Quick Folder file or a followed episode.
public enum QuickAddCandidate: Identifiable, Sendable {
    case localFile(QuickAccessFile)
    case followedSource(FeedEntry)

    public var id: String {
        switch self {
        case .localFile(let file): "local-file:\(file.id)"
        case .followedSource(let entry): "followed-source:\(entry.id)"
        }
    }

    fileprivate var sortDate: Date {
        switch self {
        case .localFile(let file): file.modifiedAt
        case .followedSource(let entry): entry.publishedAt ?? .distantPast
        }
    }
}

/// The three Library fields the Quick Add rules read, so the rules don't need the app's row type.
public struct QuickAddImportedItem: Sendable, Equatable {
    public let sourceReference: String?
    public let title: String
    public let sourceTitle: String?

    public init(sourceReference: String?, title: String, sourceTitle: String?) {
        self.sourceReference = sourceReference
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

public enum QuickAddFeed {
    /// Quick Folder files and followed episodes in one list, newest first (ties by id ascending).
    /// A file whose dismissal key was dismissed is hidden. A followed episode is hidden when a Library
    /// item has the same normalized source URL, or the same show and episode title key. A followed
    /// show's back catalogue, what it had before it was followed, is never listed (#1589).
    public static func candidates(
        folderFiles: [QuickAccessFile],
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription] = [],
        libraryItems: [QuickAddImportedItem] = [],
        dismissedFileKeys: Set<String> = []
    ) -> [QuickAddCandidate] {
        let importedURLs = Set(libraryItems.compactMap { normalizedURL($0.sourceReference) })
        let importedEpisodeKeys = Set(libraryItems.map {
            episodeKey(title: $0.title, sourceTitle: $0.sourceTitle)
        })
        let sourceTitles = Dictionary(uniqueKeysWithValues: subscriptions.map {
            ($0.id, $0.source.title ?? $0.source.host)
        })
        let eligibleFiles = folderFiles.filter { !dismissedFileKeys.contains($0.dismissalKey) }
        let eligibleEntries = FollowBaseline.newEntries(followedEntries, subscriptions: subscriptions).filter { entry in
            if let url = normalizedURL(entry.canonicalURL), importedURLs.contains(url) {
                return false
            }
            let key = episodeKey(
                title: entry.title,
                sourceTitle: sourceTitles[entry.subscriptionId]
            )
            return !importedEpisodeKeys.contains(key)
        }
        return (eligibleFiles.map(QuickAddCandidate.localFile)
            + distinctEpisodes(eligibleEntries, sourceTitles: sourceTitles).map(QuickAddCandidate.followedSource))
            .sorted {
                if $0.sortDate != $1.sortDate {
                    return $0.sortDate > $1.sortDate
                }
                return $0.id < $1.id
            }
    }

    /// One entry per episode: a show followed twice (two feed links) or a feed that lists an episode
    /// twice would show the same episode on two rows (#1440). Same show, same title and same
    /// publish time is the same episode. Episodes sharing a page link (many shows give every episode
    /// the show's address) or a title alone are different episodes and stay.
    private static func distinctEpisodes(_ entries: [FeedEntry], sourceTitles: [String: String]) -> [FeedEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            var key = episodeKey(title: entry.title, sourceTitle: sourceTitles[entry.subscriptionId] ?? entry.subscriptionId)
            // `episodeKey` keeps only ASCII letters and digits, so a title in another script is empty
            // there; its own text tells such episodes apart.
            if key.hasSuffix("|") {
                key += entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            key += "|" + (entry.publishedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "undated")
            return seen.insert(key).inserted
        }
    }

    // Copied as is. Don't merge with `FollowedSourceMatching.normalizedFollowSourceURL` or
    // `SharedItemIdentityBuilder.normalizedSharingURL`: their rules differ, and merging changes
    // which episodes are hidden.
    static func normalizedURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }

    // Copied as is. Every non-ASCII letter becomes a separator here; `SharedEpisodeFeedMatcher.normalizedTitle`
    // keeps letters, so the two must not be merged.
    static func episodeKey(title: String, sourceTitle: String?) -> String {
        [sourceTitle ?? "", title]
            .map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "|")
    }
}

/// A supported file found in the Quick Folder, before the app adds its relative-time wording.
public struct QuickAccessFileCandidate: Sendable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let modifiedAt: Date

    public init(id: String, name: String, relativePath: String, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
    }
}

public struct QuickAccessFolderScan: Sendable {
    /// The Quick Add list: the newest few importable files (`QuickAccessFolderScanner.quickAddLimit`).
    public let files: [QuickAccessFileCandidate]
    /// Every importable file in the folder, newest first, for the inbox that feeds the play queue (#3767). `files` is its
    /// first few. Without it the inbox could only ever see the newest eight, so a ninth file dropped in at the same
    /// time was never queued.
    public let inboxFiles: [QuickAccessFileCandidate]
    public let errorDescription: String?

    public init(files: [QuickAccessFileCandidate], errorDescription: String?, inboxFiles: [QuickAccessFileCandidate]? = nil) {
        self.files = files
        self.inboxFiles = inboxFiles ?? files
        self.errorDescription = errorDescription
    }
}

public enum QuickAccessFolderScanner {
    /// How many `.json` files one scan reads to tell a link list from anything else. Newer files go first, so a folder
    /// full of Listening Editions can't make a scan read without end. Each read is at most `LinkListFile.maxFileBytes`.
    public static let maxJSONReads = 40

    /// How many files the Quick Add list on Following shows.
    public static let quickAddLimit = 8

    /// The eight newest importable files directly in the folder (`files`; `inboxFiles` holds all of them): md, markdown, txt and pdf by extension, and `.json`
    /// only when the file itself says it is a structured link list (#3767, `LinkListFile.recognize`; never by name, so a
    /// Listening Edition or any other JSON never shows). Hidden files, subfolders and other extensions are skipped. An
    /// unreadable folder returns the error and no files. Reading happens here, so call it off the main actor.
    public static func scan(_ folderURL: URL) -> QuickAccessFolderScan {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let found = files.compactMap { url -> (candidate: QuickAccessFileCandidate, isJSON: Bool)? in
                let ext = url.pathExtension.lowercased()
                guard ["md", "markdown", "txt", "pdf", "json"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return (QuickAccessFileCandidate(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    relativePath: url.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                ), ext == "json")
            }
            // Newest first, ties by name so the order never depends on the directory listing.
            let newestFirst = found.sorted {
                $0.candidate.modifiedAt != $1.candidate.modifiedAt
                    ? $0.candidate.modifiedAt > $1.candidate.modifiedAt
                    : $0.candidate.relativePath < $1.candidate.relativePath
            }
            var accepted: [QuickAccessFileCandidate] = []
            var jsonReads = 0
            for entry in newestFirst {
                if entry.isJSON {
                    guard jsonReads < maxJSONReads else { continue }
                    jsonReads += 1
                    guard isLinkListFile(folderURL.appendingPathComponent(entry.candidate.relativePath)) else { continue }
                }
                accepted.append(entry.candidate)
            }
            return QuickAccessFolderScan(files: Array(accepted.prefix(quickAddLimit)), errorDescription: nil, inboxFiles: accepted)
        } catch {
            return QuickAccessFolderScan(files: [], errorDescription: SafeErrorText.describe(error))
        }
    }

    /// True when the file's own `schemaVersion` says it is a link list (valid or refused: a refused list is shown so the
    /// listener can read why). A file over the size limit is read only as far as its first 512 bytes, to see whether it
    /// announces the link-list format, so the "too large, split it" reason reaches the listener without the scan
    /// loading it. Anything unreadable is not a link list.
    static func isLinkListFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return false }
        if size > LinkListFile.maxFileBytes {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 512) else { return false }
            return head.range(of: Data(LinkListFile.schemaFamilyPrefix.utf8)) != nil
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        if case .notALinkList = LinkListFile.recognize(data) { return false }
        return true
    }
}
