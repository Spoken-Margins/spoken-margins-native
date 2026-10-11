import Foundation

/// What CarPlay may show and do (#790). The iPhone owns playback: CarPlay browses the Library and sends
/// the same play, pause and skip commands the Lock Screen sends, and shows what the phone is playing.
/// It has no player or position of its own, so nothing here can drift from the phone.
///
/// Pure and host-tested. The CarPlay templates and the scene that connect it to a car need Apple's audio
/// entitlement and run on the Mac lane; they call this and nothing else decides what a car shows or sends.

/// One Library item as a car lists it.
public struct CarPlayLibraryEntry: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// A podcast episode or other audio file.
        case audio
        /// An article, PDF or pasted text read aloud.
        case text
    }

    /// The Library item's id, which stays the same across launches and library changes.
    public var id: String
    public var title: String
    /// The show, author or site, when the item has one.
    public var subtitle: String?
    public var kind: Kind
    /// 0 to 100 of the source heard so far.
    public var progressPercent: Int
    public var lastPlayedAt: Date?

    public init(
        id: String, title: String, subtitle: String? = nil, kind: Kind,
        progressPercent: Int = 0, lastPlayedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.progressPercent = max(0, min(100, progressPercent))
        self.lastPlayedAt = lastPlayedAt
    }

    public var isFinished: Bool { progressPercent >= 100 }

    /// Item states that can play. Anything else (failed, still importing) is not offered in a car.
    private static let playableStatuses: Set<String> = ["ready", "needs_transcript", "audio_ready", "needs_listening_map"]

    /// The entry for `item`, or nil when a car should not offer it: a deleted or not-ready item, one with
    /// nothing to play, or a browser-owned video that only plays inside the browser.
    public init?(item: Item, progressPercent: Int = 0, lastPlayedAt: Date? = nil) {
        guard item.deletedAt == nil, Self.playableStatuses.contains(item.status) else { return nil }
        let kind: Kind
        switch item.media?.sourceType {
        case .some(.nativeMediaFile), .some(.remoteStream):
            let locations = [item.media?.url, item.media?.nativeMediaId]
            guard locations.contains(where: { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
                return nil
            }
            kind = .audio
        case .some(.browserOwnedMedia):
            return nil
        case .some(.generatedTTSPrerendered), .some(.generatedTTSRealtime), .none:
            guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
            kind = .text
        }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let subtitle = [item.showTitle, item.author, item.sourceTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        self.init(
            id: item.id, title: title, subtitle: subtitle, kind: kind,
            progressPercent: progressPercent, lastPlayedAt: lastPlayedAt
        )
    }
}

/// The one list a car browses.
public enum CarPlayBrowseList {
    /// Cars cap list length and a driver should not scroll: this many entries at most.
    public static let maximumEntries = 24

    /// What to show, in order: what is playing now, then what was started most recently, then what has not
    /// been started (in Library order), then what is finished. Entries with the same id appear once.
    public static func entries(from library: [CarPlayLibraryEntry], currentItemId: String?) -> [CarPlayLibraryEntry] {
        var seen = Set<String>()
        let unique = library.filter { seen.insert($0.id).inserted }
        func rank(_ entry: CarPlayLibraryEntry) -> Int {
            if entry.id == currentItemId { return 0 }
            if entry.isFinished { return 3 }
            return entry.lastPlayedAt != nil || entry.progressPercent > 0 ? 1 : 2
        }
        let ordered = unique.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element), rank(rhs.element))
            if left != right { return left < right }
            if left == 1 {
                let (leftDate, rightDate) = (lhs.element.lastPlayedAt ?? .distantPast, rhs.element.lastPlayedAt ?? .distantPast)
                if leftDate != rightDate { return leftDate > rightDate }
            }
            return lhs.offset < rhs.offset
        }
        return Array(ordered.prefix(maximumEntries).map(\.element))
    }
}

/// What a car's Now Playing screen shows. Built from the phone's own snapshot, so it is what the phone
/// is playing at its real position.
public struct CarPlayNowPlaying: Equatable, Sendable {
    public var itemId: String?
    public var title: String?
    public var chapterTitle: String?
    public var isPlaying: Bool
    public var positionMs: Int?
    public var durationMs: Int?
    /// 0 to 100 of the source, for text that has no clock.
    public var progressPercent: Int
    public var playbackRate: Double
    public var supportedCommands: [CarPlayCommand]

    public init(snapshot: CompactControlSnapshot) {
        let hasItem = snapshot.itemId != nil
        itemId = snapshot.itemId
        title = snapshot.title
        chapterTitle = snapshot.chapterTitle
        isPlaying = hasItem && snapshot.status.isPlaybackActive
        positionMs = hasItem ? snapshot.currentMediaTimeMs : nil
        durationMs = hasItem ? snapshot.currentPlaybackDurationMs : nil
        progressPercent = hasItem ? snapshot.sourceProgressPercent : 0
        playbackRate = snapshot.playbackRate
        supportedCommands = hasItem
            ? CarPlayCommand.allCases.filter { snapshot.availableCommands.contains($0.compactCommand) }
            : []
    }
}

/// The only commands a car may send. No recording, no summaries, no follow-ups (#790).
public enum CarPlayCommand: String, CaseIterable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipBack
    case skipForward

    public var compactCommand: CompactControlCommand {
        switch self {
        case .play: .play
        case .pause: .pause
        case .togglePlayPause: .togglePlayPause
        case .skipBack: .skipBack
        case .skipForward: .skipForward
        }
    }
}

/// One car connection's decisions. A value the app holds while a car is connected: it asks, and does what
/// the answer says through the phone's normal playback controls.
public struct CarPlayConnection: Sendable {
    /// The same command or pick arriving again this soon is the car repeating itself (a double tap, a
    /// steering-wheel key held down), not a second request.
    public static let repeatWindow: TimeInterval = 0.75

    public enum Ignored: Equatable, Sendable {
        case notConnected
        case duplicate
        /// Already in the state the command asks for.
        case alreadyDone
        /// The phone's playback doesn't offer the command now (nothing is loaded, or the source can't skip).
        case unavailable
    }

    public enum CommandDecision: Equatable, Sendable {
        case dispatch(CompactControlCommand)
        case ignore(Ignored)
    }

    public enum SelectionDecision: Equatable, Sendable {
        /// Start this Library item through the phone's normal start path.
        case start(itemId: String)
        /// The item is already loaded and paused: resume it where it is.
        case resumeCurrent
        case ignore(Ignored)
        /// The item left the Library or became unplayable since the list was shown. Show the list again.
        case itemGone
    }

    public private(set) var isConnected = false
    private var lastCommand: (command: CarPlayCommand, at: Date)?
    private var lastSelection: (itemId: String, at: Date)?

    public init() {}

    /// A car connected or reconnected. It returns what to show and never starts playback: whatever the
    /// phone was doing (playing, paused, or nothing) continues as it was.
    public mutating func connect(snapshot: CompactControlSnapshot) -> CarPlayNowPlaying {
        isConnected = true
        lastCommand = nil
        lastSelection = nil
        return CarPlayNowPlaying(snapshot: snapshot)
    }

    public mutating func disconnect() {
        isConnected = false
        lastCommand = nil
        lastSelection = nil
    }

    public mutating func decide(
        _ command: CarPlayCommand, snapshot: CompactControlSnapshot, now: Date = Date()
    ) -> CommandDecision {
        guard isConnected else { return .ignore(.notConnected) }
        if let last = lastCommand, last.command == command, now.timeIntervalSince(last.at) < Self.repeatWindow,
           now >= last.at {
            return .ignore(.duplicate)
        }
        let playing = snapshot.itemId != nil && snapshot.status.isPlaybackActive
        guard CarPlayNowPlaying(snapshot: snapshot).supportedCommands.contains(command) else {
            return .ignore(.unavailable)
        }
        switch command {
        case .play where playing, .pause where !playing:
            return .ignore(.alreadyDone)
        default:
            lastCommand = (command, now)
            return .dispatch(command.compactCommand)
        }
    }

    /// The listener picked `itemId` in the list. `library` is the Library as it is now, not as the list
    /// was drawn, so a pick of an item that has since gone is refused rather than played.
    public mutating func decide(
        selecting itemId: String, library: [CarPlayLibraryEntry], snapshot: CompactControlSnapshot, now: Date = Date()
    ) -> SelectionDecision {
        guard isConnected else { return .ignore(.notConnected) }
        if let last = lastSelection, last.itemId == itemId, now.timeIntervalSince(last.at) < Self.repeatWindow,
           now >= last.at {
            return .ignore(.duplicate)
        }
        guard library.contains(where: { $0.id == itemId }) else { return .itemGone }
        guard snapshot.itemId == itemId else {
            lastSelection = (itemId, now)
            return .start(itemId: itemId)
        }
        switch snapshot.status {
        case .starting, .playing:
            return .ignore(.alreadyDone)
        case .recording:
            // A Margin is being recorded on the phone: the car doesn't interrupt it.
            return .ignore(.unavailable)
        case .failed, .idle:
            lastSelection = (itemId, now)
            return .start(itemId: itemId)
        case .paused:
            guard CarPlayNowPlaying(snapshot: snapshot).supportedCommands.contains(.play) else {
                return .ignore(.unavailable)
            }
            lastSelection = (itemId, now)
            // A resume is a play: a car Play key a moment later is the same request, not a second one.
            lastCommand = (.play, now)
            return .resumeCurrent
        }
    }
}
