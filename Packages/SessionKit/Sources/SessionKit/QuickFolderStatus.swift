import Foundation

/// Every line the app says about a Quick Folder (#3770): Settings' row and screen, Following's row and screen, and the Add
/// sheet. One type, so a surface can't word the same state its own way. Pure: it is built from what the app remembers about the
/// folder and a clock, and reads nothing else.
///
/// A folder is in one of three states. **None chosen** (no name). **Can't open**: the bookmark didn't resolve or the folder
/// couldn't be listed; the icon and the words carry it, never colour. Or **working**, with a last-checked time. A folder's new
/// files only ever wait on Following for the listener to add; nothing queues them by itself (owner decision, #4274).
public struct QuickFolderStatus: Sendable {
    public enum Problem: String, Codable, Equatable, Sendable {
        /// "Can't open this folder": moved, deleted, signed out and offline can't be told apart.
        case cantOpen
    }

    /// The words for an elapsed time under a week: `spoken` false is the abbreviated style ("2 min. ago"), true the full one
    /// ("2 minutes ago"). On Apple platforms this is `RelativeDateTimeFormatter` with `dateTimeStyle = .named`; elsewhere (Linux
    /// host tests) it is a plain English version of the same.
    public struct RelativeText: Sendable {
        public var text: @Sendable (_ date: Date, _ now: Date, _ spoken: Bool, _ locale: Locale) -> String

        public init(_ text: @escaping @Sendable (Date, Date, Bool, Locale) -> String) {
            self.text = text
        }

        public static let platform = RelativeText { date, now, spoken, locale in
            #if canImport(Darwin)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = spoken ? .full : .abbreviated
            formatter.dateTimeStyle = .named
            formatter.locale = locale
            return formatter.localizedString(for: date, relativeTo: now)
            #else
            return plainEnglish(date: date, now: now, spoken: spoken)
            #endif
        }

        static func plainEnglish(date: Date, now: Date, spoken: Bool) -> String {
            let seconds = max(0, Int(now.timeIntervalSince(date)))
            func units(_ count: Int, _ short: String, _ long: String) -> String {
                "\(count) \(spoken ? (count == 1 ? long : long + "s") : short) ago"
            }
            switch seconds {
            case ..<3_600: return units(max(1, seconds / 60), "min.", "minute")
            case ..<86_400: return units(seconds / 3_600, "hr.", "hour")
            case ..<172_800: return "yesterday"
            default: return units(seconds / 86_400, "days", "day")
            }
        }
    }

    // MARK: What the app remembers

    /// The folder's name; nil, or empty, means none is chosen.
    public var name: String?
    /// The folder's path once a scan has learned it (`quickAccessFolderPath`); nil until then.
    public var path: String?
    /// When a scan last finished successfully; nil before the first.
    public var lastCheckedAt: Date?
    public var problem: Problem?
    /// New files, the count Following shows.
    public var newCount: Int

    public var now: Date
    public var calendar: Calendar
    public var locale: Locale
    public var relative: RelativeText

    public init(
        name: String?, path: String? = nil, lastCheckedAt: Date? = nil, problem: Problem? = nil,
        newCount: Int = 0,
        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current, relative: RelativeText = .platform
    ) {
        self.name = name
        self.path = path
        self.lastCheckedAt = lastCheckedAt
        self.problem = problem
        self.newCount = max(0, newCount)
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.relative = relative
    }

    // MARK: State

    public static let noneChosen = "None chosen"
    /// The one thing a folder does with new files (#4274): they wait on Following until the listener adds them.
    public static let newFilesPhrase = "New files wait in Following"
    public static let cantOpenTitle = "Can't open this folder"
    public static let cantOpenMessage = "It may have been moved, deleted or signed out, or it may be offline. Check again, or choose it again."
    public static let cantOpenSymbol = "exclamationmark.triangle"

    public var hasFolder: Bool { !(name ?? "").isEmpty }
    public var cantOpen: Bool { hasFolder && problem == .cantOpen }
    /// The folder's name, or "Quick Folder" when none is chosen.
    public var displayName: String { hasFolder ? name! : "Quick Folder" }

    /// "iCloud Drive › Obsidian › Clippings". Nil until the app knows the path, so a row never shows a guess.
    public var locationLine: String? { path.flatMap(FolderLocationLabel.label(forPath:)) }

    // MARK: Settings > Import & Export, the row

    /// Line 2 of the row: the location, hidden until it is known.
    public var settingsLocationLine: String? { hasFolder ? locationLine : nil }

    /// Line 3 of the row. With no folder, "None chosen". When the folder can't be opened, that replaces the line entirely, with
    /// no suffix. Otherwise the check part, then the phrase: "Checked 2 min. ago · New files wait in Following".
    public var settingsStatusLine: String {
        guard hasFolder else { return Self.noneChosen }
        if cantOpen { return Self.cantOpenTitle }
        return "\(checkedText) · \(Self.newFilesPhrase)"
    }

    /// The symbol drawn beside line 3: the warning triangle when the folder can't be opened, else none.
    public var settingsStatusSymbol: String? { cantOpen ? Self.cantOpenSymbol : nil }

    /// "Quick Folder, Clippings, in iCloud Drive, Obsidian, Clippings, checked 2 minutes ago, new files wait in Following".
    public var settingsAccessibilityLabel: String {
        guard hasFolder else { return "Quick Folder, none chosen" }
        var parts = ["Quick Folder", displayName]
        if cantOpen { return (parts + ["can't open this folder"]).joined(separator: ", ") }
        if let spoken = path.flatMap(FolderLocationLabel.spokenLabel(forPath:)) { parts.append("in \(spoken)") }
        parts.append(spokenCheckedText)
        parts.append(Self.newFilesPhrase.lowercasedFirst)
        return parts.joined(separator: ", ")
    }

    // MARK: "Checked" wording

    /// "Not checked yet", "Checked just now", "Checked 2 min. ago", "Checked yesterday", "Checked Nov 3", "Checked Nov 3, 2025".
    public var checkedText: String { checkedWording(spoken: false) }
    /// The same for VoiceOver: "checked just now", "checked 2 minutes ago". "Not checked yet" stays.
    public var spokenCheckedText: String {
        let spoken = checkedWording(spoken: true)
        return lastCheckedAt == nil ? spoken : spoken.lowercasedFirst
    }

    /// Under 60 seconds is "just now"; under 7 days the relative form; 7 days or more the date, with the year added when it is
    /// not the current year. A time in the future counts as just now.
    private func checkedWording(spoken: Bool) -> String {
        guard let date = lastCheckedAt else { return "Not checked yet" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Checked just now" }
        if elapsed < 7 * 86_400 { return "Checked " + relative.text(date, now, spoken, locale) }
        var style = Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return "Checked " + date.formatted(style)
    }

    // MARK: The Quick Folder screen

    public static let sectionFooter = "Files you save to a Quick Folder show up in Following, where you choose what to add."
    public static let newFilesFooter = "New files are listed on Following for you to add. Files saved on another device appear once they have synced to this iPhone."
    public static let addSheetFootnote = "You can also see and change it in Settings › Import & Export."
    /// Under the Quick Folder rows in Settings and the Add sheet's Quick Folder route, while fewer than `QuickFolderList.limit`
    /// folders are chosen (#3770, Design PR 5).
    public static let addAnotherTitle = "Add Another Folder"
    /// Shown in place of Add Another Folder once `QuickFolderList.limit` folders are chosen.
    public static let limitFootnote = "Up to \(QuickFolderList.limit) Quick Folders."
    /// The same folder chosen a second time, as a new folder or as another folder's Change Folder.
    public static let duplicateFolderMessage = "That folder is already a Quick Folder."
    /// A folder added past the limit (Add Another Folder is hidden then, so only a race reaches it).
    public static let fullMessage = "You already have \(QuickFolderList.limit) Quick Folders. Remove one in Settings to add another."

    /// The "Last checked" value: the time, "Checking…" while a scan runs, or "Not checked yet".
    public func lastCheckedValue(isChecking: Bool) -> String {
        if isChecking { return "Checking…" }
        guard let date = lastCheckedAt else { return "Not checked yet" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// The "New files" value: "3 new" or "None new". The count Following shows.
    public var newFilesValue: String { newCount > 0 ? "\(newCount) new" : "None new" }

    /// The confirmation before removing: nothing in the Library or the queue goes.
    public var removeConfirmationTitle: String { "Stop importing from “\(displayName)”?" }
    public static let removeConfirmationMessage = "Nothing already in your Library or play queue is removed, and the folder's files stay where they are."

    // MARK: Following

    /// Following lists the folder when it has new files, and also when it can't be opened: a silent broken folder is the
    /// complaint this answers.
    public var isListedOnFollowing: Bool { hasFolder && (newCount > 0 || cantOpen) }

    /// The row's title: the folder's name.
    public var followingTitle: String { displayName }

    /// "Quick Folder · 3 new", or "Quick Folder · can't open this folder".
    public var followingSubtitle: String {
        cantOpen ? "Quick Folder · can't open this folder" : "Quick Folder · \(newCount) new"
    }

    public var followingSymbol: String? { cantOpen ? Self.cantOpenSymbol : nil }

    /// "Clippings, Quick Folder, 3 new" or "Clippings, Quick Folder, can't open this folder".
    public var followingAccessibilityLabel: String {
        "\(displayName), Quick Folder, " + (cantOpen ? "can't open this folder" : "\(newCount) new")
    }

    /// The first line of Following's folder screen: "Quick Folder · <location>", or "Quick Folder" while the location is unknown.
    public var followingScreenFirstLine: String {
        locationLine.map { "Quick Folder · \($0)" } ?? "Quick Folder"
    }

    /// File captions read "Clippings · <date>" instead of "Quick Folder · <date>".
    public func fileCaption(dateText: String) -> String { "\(displayName) · \(dateText)" }
}

private extension String {
    var lowercasedFirst: String { first.map { $0.lowercased() + dropFirst() } ?? self }
}
