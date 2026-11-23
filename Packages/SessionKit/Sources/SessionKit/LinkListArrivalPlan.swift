#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What the app does with a link list that has reached it, decided before anything is added (#4683, Design section 2f).
///
/// Four entries lead to one arrival: the Quick Folder (on its own, or tapped), Paste & go, and the handoff folder. Each
/// builds this plan from the list it found and then runs the same steps, so one list gets the same key, the same links
/// to add, the same shows to suggest and the same banner whichever way it came (the #4097 lesson). Pure: no store,
/// no network, no UI; the app runs the plan and the rules are tested here.
public struct LinkListArrivalPlan: Equatable, Sendable {
    /// Where the list came from. The plan is the same for every route; the route only decides what the app does around it.
    public enum Route: String, CaseIterable, Sendable {
        case quickFolderAutomatic
        case quickFolderTapped
        case pasteAndGo
        case handoffFolder
    }

    public enum Attempt: Equatable, Sendable {
        /// Online (or not known to be offline): add the links.
        case attempt
        /// Offline: add nothing and count no try. The list is kept, or the listener is asked to paste it again.
        case waitOffline
    }

    /// The made-up path an arrival uses where a file's path would go, so the same list is one collection whichever way
    /// it arrives and whatever the file is called.
    public static let keyPrefix = "linklist:"

    /// `linklist:` plus the lowercase hex SHA-256 of the list.
    public let key: String
    /// The list's title, or nil for an untitled list. A titled list becomes a collection; an untitled one, loose items.
    public let title: String?
    /// The entries to add as items, in the list's order. Follow entries are not here.
    public let links: [LinkListFile.Entry]
    /// The feed links to suggest following, in the list's order, minus the shows already followed.
    public let followURLs: [String]
    /// Entries the list had that the app will not take (not https, no link).
    public let skipped: [LinkListFile.SkippedEntry]
    public let attempt: Attempt

    public var isTitled: Bool { title != nil }
    public var hasLinks: Bool { !links.isEmpty }

    /// The list narrowed to what is added as items, in the form the importers take.
    public var itemList: LinkListFile { LinkListFile(title: title, entries: links, skipped: skipped) }

    /// - Parameters:
    ///   - followedFeedKeys: `FeedURLKey`s of the shows the listener already follows; a follow entry for one is dropped.
    ///   - isOffline: `ConnectivityProviding.isOffline`.
    public static func make(list: LinkListFile, followedFeedKeys: Set<String> = [], isOffline: Bool) -> LinkListArrivalPlan {
        let title = list.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let followURLs = list.entries.filter(\.follow).map(\.url).filter { url in
            guard let feedKey = FeedURLKey.make(url) else { return true }
            return !followedFeedKeys.contains(feedKey)
        }
        return LinkListArrivalPlan(
            key: key(for: list),
            title: (title?.isEmpty ?? true) ? nil : title,
            links: list.entries.filter { !$0.follow },
            followURLs: followURLs,
            skipped: list.skipped,
            attempt: isOffline ? .waitOffline : .attempt)
    }

    /// `linklist:` plus the lowercase hex SHA-256 of the list's title (or nothing) and each entry's link, joined by
    /// newlines, in file order. A list saved under the same name each day with new links is a new key, so a new collection.
    public static func key(for list: LinkListFile) -> String {
        let text = ([list.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""] + list.entries.map(\.url)).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return keyPrefix + digest
    }

    // MARK: - Pasted text

    /// What Paste & go makes of copied text before it looks at links.
    public enum PastedText: Equatable, Sendable {
        /// No link list marker: ordinary text or a link, which goes the way it always did.
        case notALinkList
        /// The marker is there: read it as a reply from the listener's AI.
        case mightBeLinkList
        /// The prompt the app itself gives the listener to copy into their AI. It holds the marker and an example list
        /// with example.com links, and must never be added as a brief.
        case assistantPrompt
    }

    public static let assistantPromptMessage =
        "That's the prompt for your AI. Paste it into a chat with your AI, then copy its reply and paste that here."

    public static func classifyPaste(_ text: String) -> PastedText {
        guard LinkListText.mightContain(text) else { return .notALinkList }
        return AssistantSetupPrompt.isPrompt(text) ? .assistantPrompt : .mightBeLinkList
    }

    // MARK: - What the listener is told

    public struct Banner: Equatable, Sendable {
        public var message: String
        public var kind: LibraryCollectionImport.Summary.Kind
        /// Whether the banner carries an Undo for the items this arrival made.
        public var offersUndo: Bool
    }

    /// The banner for one arrival.
    /// - Parameters:
    ///   - base: the line the import itself gives (`LibraryCollectionImport.summary` for a titled list, the loose-items
    ///     line for an untitled one), or nil when the list had no links to add (only follow entries).
    ///   - suggested: how many shows went to the suggestions.
    ///   - madeItems: whether the arrival made at least one new item.
    ///   - collectionIsNew: for a titled list, whether the collection is new.
    ///   - mentionsFollowing: whether Following can show the suggestions yet (it can from the suggestions row on).
    public static func banner(
        base: LibraryCollectionImport.Summary?,
        suggested: Int,
        madeItems: Bool,
        isTitled: Bool,
        collectionIsNew: Bool,
        mentionsFollowing: Bool
    ) -> Banner {
        let offersUndo = madeItems && (!isTitled || collectionIsNew)
        guard let base else {
            guard suggested > 0 else {
                return Banner(message: "Those shows are already in Following.", kind: .success, offersUndo: false)
            }
            let tail = mentionsFollowing ? " They're at the top of Following." : ""
            return Banner(message: "Your AI suggested \(shows(suggested)).\(tail)", kind: .success, offersUndo: false)
        }
        var message = base.message
        if suggested > 0, mentionsFollowing {
            message += " \(shows(suggested)) to review in Following."
        }
        return Banner(message: message, kind: base.kind, offersUndo: offersUndo)
    }

    private static func shows(_ count: Int) -> String { count == 1 ? "1 show" : "\(count) shows" }

    // MARK: - Undo

    /// The items Undo moves to Recently Deleted: those the import reported as added that were not in the Library just
    /// before the arrival, minus the item now playing, each once and in the order they were added. An item that was
    /// already there keeps its progress and its Margins.
    public static func undoItemIDs(added: [String], libraryBefore: Set<String>, playing: String?) -> [String] {
        var seen = Set<String>()
        return added.filter { id in
            !libraryBefore.contains(id) && id != playing && seen.insert(id).inserted
        }
    }

    // MARK: - Retry

    public enum Settlement: Equatable, Sendable {
        /// Every link landed (or was already there): the list is done and leaves the Quick Add list.
        case done
        /// A link failed while online and the list has tries left: it is tried again at the next refresh.
        case retryLater
        /// The list failed `LinkListRetryLedger.maxTries` times: it stays in Quick Add for a tap, as before.
        case stayForTap
    }

    /// - Parameters:
    ///   - allLanded: no link failed. Entries the list itself got wrong (not https) never land and don't count.
    ///   - triesAfterThisAttempt: the ledger's count after this attempt, counted only when it failed online.
    public static func settlement(allLanded: Bool, triesAfterThisAttempt: Int) -> Settlement {
        if allLanded { return .done }
        return triesAfterThisAttempt >= LinkListRetryLedger.maxTries ? .stayForTap : .retryLater
    }
}

/// The last link list that added an item or a suggestion, kept in `UserDefaults` so the Your AI screen (PR 4 of
/// #4683) can say when and what arrived, and so it survives a relaunch (#4683, Design section 2f, item 9).
public struct LinkListArrivalRecord: Codable, Equatable, Sendable {
    public static let defaultsKey = "lastLinkListArrivalV1"

    /// The list's title, nil for an untitled list.
    public var title: String?
    public var date: Date

    public init(title: String?, date: Date) {
        self.title = title
        self.date = date
    }

    public static func load(from defaults: UserDefaults = .standard) -> LinkListArrivalRecord? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Data this build can't read counts as no record, and the next arrival overwrites it.
        return try? decoder.decode(LinkListArrivalRecord.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
