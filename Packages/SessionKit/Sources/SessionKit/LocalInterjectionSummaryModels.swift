import Foundation

/// The values the on-device language model reads and writes when it labels a listening map and summarizes
/// dictated interjections. They are plain Codable data, so the app's model client and its rule checks both
/// take them from here and the rules can be tested on the host.

/// One chapter's label for the listening map: a short title and a one-line description, plus the scene
/// eligibility the model judged for it when it was asked to.
public struct LocalListeningMapLabel: Codable, Equatable, Sendable {
    public let title: String
    public let description: String
    public var eligibility: PortableSceneEligibility?
    public var eligibilityReason: String?

    public init(
        title: String,
        description: String,
        eligibility: PortableSceneEligibility? = nil,
        eligibilityReason: String? = nil
    ) {
        self.title = title
        self.description = description
        self.eligibility = eligibility
        self.eligibilityReason = eligibilityReason
    }
}

/// One dictated interjection with the source words on either side of it.
public struct LocalInterjectionSummaryRecord: Codable, Equatable, Sendable {
    public let id: String
    public let anchorBefore: String
    public let anchorAfter: String
    public let note: String

    public init(id: String, anchorBefore: String, anchorAfter: String, note: String) {
        self.id = id
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.note = note
    }
}

/// Everything the model is given to summarize one item's interjections, as the JSON context string it reads.
public struct LocalInterjectionSummaryPayload: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let itemTitle: String
    public let interjections: [LocalInterjectionSummaryRecord]

    public init(schemaVersion: String, itemTitle: String, interjections: [LocalInterjectionSummaryRecord]) {
        self.schemaVersion = schemaVersion
        self.itemTitle = itemTitle
        self.interjections = interjections
    }
}

/// What one interjection says, boiled down to an optional question and the points it makes.
public struct LocalInterjectionMeaningSlots: Codable, Equatable, Sendable {
    public let question: String?
    public let points: [String]

    public init(question: String?, points: [String]) {
        self.question = question
        self.points = points
    }
}
