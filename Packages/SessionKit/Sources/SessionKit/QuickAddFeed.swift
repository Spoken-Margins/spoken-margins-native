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
    /// item has the same normalized source URL, or the same show and episode title key.
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
        let eligibleEntries = followedEntries.filter { entry in
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
    public let files: [QuickAccessFileCandidate]
    public let errorDescription: String?

    public init(files: [QuickAccessFileCandidate], errorDescription: String?) {
        self.files = files
        self.errorDescription = errorDescription
    }
}

public enum QuickAccessFolderScanner {
    /// The eight newest importable files (md, markdown, txt, pdf) directly in the folder. Hidden files,
    /// subfolders and other extensions are skipped. An unreadable folder returns the error and no files.
    public static func scan(_ folderURL: URL) -> QuickAccessFolderScan {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let supported = files.compactMap { url -> QuickAccessFileCandidate? in
                let ext = url.pathExtension.lowercased()
                guard ["md", "markdown", "txt", "pdf"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return QuickAccessFileCandidate(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    relativePath: url.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            return QuickAccessFolderScan(
                files: Array(supported.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)),
                errorDescription: nil
            )
        } catch {
            return QuickAccessFolderScan(files: [], errorDescription: String(describing: error))
        }
    }
}
