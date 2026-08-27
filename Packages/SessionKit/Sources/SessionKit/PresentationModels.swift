import Foundation

public enum LibraryContentTypeFilter: String, Codable, Equatable, CaseIterable, Sendable {
    case all
    case text
    case pdf
    case epub
    case article
    case podcast
    case audiobook
}

public enum LibraryListeningStateFilter: String, Codable, Equatable, CaseIterable, Sendable {
    case all
    case unplayed
    case inProgress = "in_progress"
    case completed
}

public enum LibraryOfflineStateFilter: String, Codable, Equatable, CaseIterable, Sendable {
    case all
    case preparing
    case readyOffline = "ready_offline"
    case needsRepreparation = "needs_repreparation"
    case onlineOnly = "online_only"
}

public enum LibrarySort: String, Codable, Equatable, CaseIterable, Sendable {
    case recentlyAdded = "recently_added"
    case recentlyListened = "recently_listened"
    case title
    case progress
}

public struct LibraryQuery: Codable, Equatable, Sendable {
    public var query: String
    public var contentType: LibraryContentTypeFilter
    public var listeningState: LibraryListeningStateFilter
    public var offlineState: LibraryOfflineStateFilter
    public var sort: LibrarySort

    public init(
        query: String = "",
        contentType: LibraryContentTypeFilter = .all,
        listeningState: LibraryListeningStateFilter = .all,
        offlineState: LibraryOfflineStateFilter = .all,
        sort: LibrarySort = .recentlyAdded
    ) {
        self.query = query
        self.contentType = contentType
        self.listeningState = listeningState
        self.offlineState = offlineState
        self.sort = sort
    }

    public var persistedSelection: LibraryQuery {
        var copy = self
        copy.query = ""
        return copy
    }
}

public enum SleepTimerMode: String, Codable, Equatable, Sendable {
    case minutes15 = "minutes_15"
    case minutes30 = "minutes_30"
    case minutes45 = "minutes_45"
    case minutes60 = "minutes_60"
    case endOfChapter = "end_of_chapter"
}

public enum SleepTimerState: Equatable, Sendable {
    case inactive
    case armed(mode: SleepTimerMode, deadline: Date?, chapterId: String?)
    case expiryDeferred(mode: SleepTimerMode)
}

public enum OnboardingRoute: String, Codable, Equatable, CaseIterable, Sendable {
    case addPDF = "add_pdf"
    case pasteText = "paste_text"
    case addWebpage = "add_webpage"
    case addPodcast = "add_podcast"
    case importEPUB = "import_epub"
    case importAudiobook = "import_audiobook"
}

public struct OnboardingAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var route: OnboardingRoute

    public init(id: String, title: String, route: OnboardingRoute) {
        self.id = id
        self.title = title
        self.route = route
    }
}

public struct GuidedOnboardingManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var itemId: String
    public var contentVersion: Int
    public var title: String
    public var description: String
    public var audioURL: String
    public var audioChecksumSHA256: String
    public var actions: [OnboardingAction]

    public init(schemaVersion: String = "guided-onboarding.v1", itemId: String, contentVersion: Int, title: String, description: String, audioURL: String, audioChecksumSHA256: String, actions: [OnboardingAction]) {
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.contentVersion = contentVersion
        self.title = title
        self.description = description
        self.audioURL = audioURL
        self.audioChecksumSHA256 = audioChecksumSHA256
        self.actions = actions
    }
}
