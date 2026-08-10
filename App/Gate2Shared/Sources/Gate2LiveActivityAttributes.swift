import Foundation

#if canImport(ActivityKit)
import ActivityKit

public struct Gate2LiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var chapterTitle: String
        public var nextChapterTitle: String?
        public var nextChapterId: String?
        public var status: String
        public var phase: String
        public var progressPercent: Int
        public var isRecording: Bool
        public var availableCommands: [String]

        private enum CodingKeys: String, CodingKey {
            case title
            case chapterTitle
            case nextChapterTitle
            case nextChapterId
            case status
            case phase
            case progressPercent
            case isRecording
            case availableCommands
        }

        public init(
            title: String,
            chapterTitle: String,
            nextChapterTitle: String? = nil,
            nextChapterId: String? = nil,
            status: String,
            phase: String,
            progressPercent: Int,
            isRecording: Bool,
            availableCommands: [String] = []
        ) {
            self.title = title
            self.chapterTitle = chapterTitle
            self.nextChapterTitle = nextChapterTitle
            self.nextChapterId = nextChapterId
            self.status = status
            self.phase = phase
            self.progressPercent = progressPercent
            self.isRecording = isRecording
            self.availableCommands = availableCommands
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            chapterTitle = try container.decode(String.self, forKey: .chapterTitle)
            nextChapterTitle = try container.decodeIfPresent(String.self, forKey: .nextChapterTitle)
            nextChapterId = try container.decodeIfPresent(String.self, forKey: .nextChapterId)
            status = try container.decode(String.self, forKey: .status)
            phase = try container.decode(String.self, forKey: .phase)
            progressPercent = try container.decode(Int.self, forKey: .progressPercent)
            isRecording = try container.decode(Bool.self, forKey: .isRecording)
            availableCommands = try container.decodeIfPresent([String].self, forKey: .availableCommands) ?? []
        }
    }

    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}
#endif
