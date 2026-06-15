import Foundation

public struct SessionExport: Codable, Equatable {
    public var schemaVersion: String = "session-export.v1"
    public var item: ExportItem
    public var session: ExportSession
    public var listeningMap: ListeningMap?
    public var turns: [ConversationTurn]
    public var timeline: [ExportTimelineEntry]
    public var interjections: [ExportInterjection]
}

public struct ExportItem: Codable, Equatable {
    public var id: String
    public var title: String
    public var externalReference: String?
    public var includedFullText: Bool
    public var text: String?
}

public struct ExportSession: Codable, Equatable {
    public var id: String
    public var status: String
    public var completionPercent: Int
}

public struct ExportTimelineEntry: Codable, Equatable {
    public var type: String
    public var interjectionId: String?
    public var turnId: String?
    public var targetType: String?
    public var targetId: String?
    public var percent: Int?
    public var chapterId: String?
}

public struct ExportInterjection: Codable, Equatable {
    public var id: String
    public var sessionId: String
    public var targetType: String
    public var targetId: String
    public var roughPercent: Int
    public var anchorBefore: String
    public var anchorAfter: String
    public var mediaTimeMs: Int?
    public var transcriptionStatus: String
    public var transcript: String?
    public var audioPath: String?
}

public struct ExportOptions: Equatable {
    public var sessionId: String?
    public var includeFullText: Bool
    public var includeReference: Bool
    public var includeListeningMap: Bool
    public var includeInterjections: Bool

    public init(
        sessionId: String? = nil,
        includeFullText: Bool,
        includeReference: Bool,
        includeListeningMap: Bool,
        includeInterjections: Bool
    ) {
        self.sessionId = sessionId
        self.includeFullText = includeFullText
        self.includeReference = includeReference
        self.includeListeningMap = includeListeningMap
        self.includeInterjections = includeInterjections
    }
}
