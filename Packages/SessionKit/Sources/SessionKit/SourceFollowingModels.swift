import Foundation

public enum SourceIdentityKind: String, Codable, Equatable, Sendable {
    case podcastFeed = "podcast_feed"
    case articleFeed = "article_feed"
    case website
}

public struct SourceIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceIdentityKind
    public var canonicalURL: String
    public var host: String
    public var title: String?

    public init(id: String, kind: SourceIdentityKind, canonicalURL: String, host: String, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.canonicalURL = canonicalURL
        self.host = host
        self.title = title
    }
}

public struct SourceCandidateEvidence: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var source: SourceIdentity
    public var evidenceURL: String
    public var relation: String
    public var confidence: Double

    public init(id: String, source: SourceIdentity, evidenceURL: String, relation: String, confidence: Double) {
        self.id = id
        self.source = source
        self.evidenceURL = evidenceURL
        self.relation = relation
        self.confidence = confidence
    }
}

public enum FeedSubscriptionState: String, Codable, Equatable, Sendable {
    case active
    case muted
}

public struct FeedSubscription: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var source: SourceIdentity
    public var state: FeedSubscriptionState
    public var etag: String?
    public var lastModified: String?
    public var lastRefreshAt: Date?
    public var createdAt: Date

    public init(id: String, source: SourceIdentity, state: FeedSubscriptionState = .active, etag: String? = nil, lastModified: String? = nil, lastRefreshAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.state = state
        self.etag = etag
        self.lastModified = lastModified
        self.lastRefreshAt = lastRefreshAt
        self.createdAt = createdAt
    }
}

public enum FeedEntryState: String, Codable, Equatable, Sendable {
    case unseen
    case seen
    case dismissed
    case imported
}

public struct FeedEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var subscriptionId: String
    public var canonicalURL: String
    public var title: String
    public var author: String?
    public var summary: String?
    public var publishedAt: Date?
    public var state: FeedEntryState

    public init(id: String, subscriptionId: String, canonicalURL: String, title: String, author: String? = nil, summary: String? = nil, publishedAt: Date? = nil, state: FeedEntryState = .unseen) {
        self.id = id
        self.subscriptionId = subscriptionId
        self.canonicalURL = canonicalURL
        self.title = title
        self.author = author
        self.summary = summary
        self.publishedAt = publishedAt
        self.state = state
    }
}

public enum FeedRefreshStatus: String, Codable, Equatable, Sendable {
    case idle
    case refreshing
    case notModified = "not_modified"
    case succeeded
    case failed
}

public struct FeedRefreshState: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var subscriptionId: String
    public var status: FeedRefreshStatus
    public var checkedAt: Date
    public var redactedHost: String
    public var errorCode: String?

    public init(id: String, subscriptionId: String, status: FeedRefreshStatus, checkedAt: Date = Date(), redactedHost: String, errorCode: String? = nil) {
        self.id = id
        self.subscriptionId = subscriptionId
        self.status = status
        self.checkedAt = checkedAt
        self.redactedHost = redactedHost
        self.errorCode = errorCode
    }
}

public enum SourceSuggestionDecisionKind: String, Codable, Equatable, Sendable {
    case prompted
    case accepted
    case notNow = "not_now"
    case neverSuggest = "never_suggest"
}

public struct SourceSuggestionDecision: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceId: String
    public var decision: SourceSuggestionDecisionKind
    public var decidedAt: Date
    public var suppressUntil: Date?
    public var lastPromptAt: Date?

    public init(id: String, sourceId: String, decision: SourceSuggestionDecisionKind, decidedAt: Date = Date(), suppressUntil: Date? = nil, lastPromptAt: Date? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.decision = decision
        self.decidedAt = decidedAt
        self.suppressUntil = suppressUntil
        self.lastPromptAt = lastPromptAt
    }
}
